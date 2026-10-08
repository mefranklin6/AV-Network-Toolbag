import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

const _workingBufferSize = 15 * 1024;

/// A Dart-owned snapshot returned by Windows' GetAdaptersAddresses API.
///
/// The FFI buffer is freed before this object is created, so callers never
/// retain pointers into native memory.
class WindowsAdapterInfo {
  const WindowsAdapterInfo({
    required this.alias,
    required this.description,
    required this.adapterName,
    required this.status,
    required this.macAddress,
    required this.linkSpeed,
    required this.interfaceIndex,
    required this.interfaceType,
    required this.ipv4Enabled,
    required this.ipv6Enabled,
    required this.dhcpEnabled,
    required this.ipv4,
    required this.ipv6,
    required this.dnsServers,
    required this.dhcpServer,
  });

  factory WindowsAdapterInfo.fromMap(Map<Object?, Object?> map) =>
      WindowsAdapterInfo(
        alias: map['alias']! as String,
        description: map['description']! as String,
        adapterName: map['adapterName']! as String,
        status: map['status']! as String,
        macAddress: map['macAddress']! as String,
        linkSpeed: map['linkSpeed']! as String,
        interfaceIndex: map['interfaceIndex']! as int,
        interfaceType: map['interfaceType']! as int,
        ipv4Enabled: map['ipv4Enabled']! as bool,
        ipv6Enabled: map['ipv6Enabled']! as bool,
        dhcpEnabled: map['dhcpEnabled']! as bool,
        ipv4: (map['ipv4']! as List<Object?>)
            .map((value) => Map<String, Object?>.from(value! as Map))
            .toList(),
        ipv6: (map['ipv6']! as List<Object?>).cast<String>(),
        dnsServers: (map['dnsServers']! as List<Object?>).cast<String>(),
        dhcpServer: map['dhcpServer']! as String,
      );

  final String alias;
  final String description;
  final String adapterName;
  final String status;
  final String macAddress;
  final String linkSpeed;
  final int interfaceIndex;
  final int interfaceType;
  final bool ipv4Enabled;
  final bool ipv6Enabled;
  final bool dhcpEnabled;
  final List<Map<String, Object?>> ipv4;
  final List<String> ipv6;
  final List<String> dnsServers;
  final String dhcpServer;

  bool get isVirtual =>
      alias.startsWith('vEthernet (') ||
      description.toLowerCase().contains('virtual') ||
      description.toLowerCase().contains('hyper-v');
}

/// Runs in a worker isolate. Only sendable Dart collections leave this method.
List<Map<String, Object?>> queryWindowsAdapters() {
  if (!Platform.isWindows) return const [];

  final size = calloc<Uint32>()..value = _workingBufferSize;
  Pointer<Uint8> buffer = calloc<Uint8>(_workingBufferSize);
  try {
    const rawFlags =
        0x0010 | // GAA_FLAG_INCLUDE_PREFIX
        0x0080 | // GAA_FLAG_INCLUDE_GATEWAYS
        0x0100; // GAA_FLAG_INCLUDE_ALL_INTERFACES
    var result = GetAdaptersAddresses(
      AF_UNSPEC,
      const GET_ADAPTERS_ADDRESSES_FLAGS(rawFlags),
      buffer.cast<IP_ADAPTER_ADDRESSES_LH>(),
      size,
    );
    if (result == ERROR_BUFFER_OVERFLOW) {
      calloc.free(buffer);
      buffer = calloc<Uint8>(size.value);
      result = GetAdaptersAddresses(
        AF_UNSPEC,
        const GET_ADAPTERS_ADDRESSES_FLAGS(rawFlags),
        buffer.cast<IP_ADAPTER_ADDRESSES_LH>(),
        size,
      );
    }
    if (result != 0) {
      throw StateError(
        'GetAdaptersAddresses failed with Windows error $result.',
      );
    }

    final adapters = <Map<String, Object?>>[];
    var current = buffer.cast<IP_ADAPTER_ADDRESSES_LH>();
    while (current.address != 0) {
      final row = current.ref;
      final ipv4 = <Map<String, Object?>>[];
      final ipv6 = <String>[];
      var unicast = row.FirstUnicastAddress;
      while (unicast.address != 0) {
        final address = unicast.ref;
        if (address.DadState != IpDadStateDuplicate) {
          final text = _socketAddressToString(address.Address);
          if (text != null) {
            if (address.Address.lpSockaddr.ref.sa_family == AF_INET) {
              ipv4.add({
                'address': text,
                'prefixLength': address.OnLinkPrefixLength,
                'subnetMask': prefixToSubnetMask(address.OnLinkPrefixLength),
                'origin': _prefixOriginName(address.PrefixOrigin),
              });
            } else if (address.Address.lpSockaddr.ref.sa_family == AF_INET6) {
              ipv6.add(text);
            }
          }
        }
        unicast = address.Next;
      }

      final dnsServers = <String>[];
      var dns = row.FirstDnsServerAddress;
      while (dns.address != 0) {
        final text = _socketAddressToString(dns.ref.Address);
        if (text != null && !dnsServers.contains(text)) {
          dnsServers.add(text);
        }
        dns = dns.ref.Next;
      }

      final mac = <String>[];
      for (var i = 0; i < row.PhysicalAddressLength; i++) {
        mac.add(row.PhysicalAddress[i].toRadixString(16).padLeft(2, '0'));
      }
      final speed = row.ReceiveLinkSpeed > row.TransmitLinkSpeed
          ? row.ReceiveLinkSpeed
          : row.TransmitLinkSpeed;
      adapters.add({
        'alias': row.FriendlyName.address == 0
            ? ''
            : row.FriendlyName.toDartString(),
        'description': row.Description.address == 0
            ? ''
            : row.Description.toDartString(),
        'adapterName': row.AdapterName.address == 0
            ? ''
            : row.AdapterName.toDartString(),
        'status': _operationalStatusName(row.OperStatus),
        'macAddress': mac.join('-').toUpperCase(),
        'linkSpeed': _formatLinkSpeed(speed),
        'interfaceIndex': row.IfIndex,
        'interfaceType': row.IfType,
        'ipv4Enabled': row.Ipv4Enabled != 0,
        'ipv6Enabled': row.Ipv6Enabled != 0,
        'dhcpEnabled': row.Dhcpv4Enabled != 0,
        'ipv4': ipv4,
        'ipv6': ipv6,
        'dnsServers': dnsServers,
        'dhcpServer': _socketAddressToString(row.Dhcpv4Server) ?? '',
      });
      current = row.Next;
    }
    adapters.removeWhere((adapter) => !_isUserVisibleAdapter(adapter));
    adapters.sort(
      (left, right) => (left['alias']! as String).toLowerCase().compareTo(
        (right['alias']! as String).toLowerCase(),
      ),
    );
    return adapters;
  } finally {
    calloc.free(buffer);
    calloc.free(size);
  }
}

bool _isUserVisibleAdapter(Map<String, Object?> adapter) {
  final type = adapter['interfaceType']! as int;
  if (type == 23 || type == 24 || type == 131) return false;
  final alias = (adapter['alias']! as String).toLowerCase();
  final description = (adapter['description']! as String).toLowerCase();
  const hiddenFragments = [
    '-npcap packet driver',
    '-qos packet scheduler',
    '-wfp 802.3 mac layer',
    '-wfp native mac layer',
    '-hyper-v virtual switch extension filter',
  ];
  if (hiddenFragments.any(
    (fragment) => alias.contains(fragment) || description.contains(fragment),
  )) {
    return false;
  }
  if (description.startsWith('wan miniport') ||
      description.startsWith('software loopback') ||
      description.startsWith('microsoft kernel debug') ||
      description.startsWith('hyper-v virtual switch extension adapter')) {
    return false;
  }
  return true;
}

String prefixToSubnetMask(int prefixLength) {
  if (prefixLength < 0 || prefixLength > 32) {
    throw RangeError.range(prefixLength, 0, 32, 'prefixLength');
  }
  return List<String>.generate(4, (index) {
    final bits = (prefixLength - (index * 8)).clamp(0, 8).toInt();
    return (bits == 0 ? 0 : 256 - (1 << (8 - bits))).toString();
  }).join('.');
}

String? _socketAddressToString(SOCKET_ADDRESS address) {
  final pointer = address.lpSockaddr;
  if (pointer.address == 0 || address.iSockaddrLength < 8) return null;
  final family = pointer.ref.sa_family;
  final bytes = pointer.cast<Uint8>().asTypedList(address.iSockaddrLength);
  if (family == AF_INET && bytes.length >= 8) {
    return '${bytes[4]}.${bytes[5]}.${bytes[6]}.${bytes[7]}';
  }
  if (family == AF_INET6 && bytes.length >= 24) {
    final text = InternetAddress.fromRawAddress(
      Uint8List.fromList(bytes.sublist(8, 24)),
    ).address;
    if (bytes.length < 28 || !text.toLowerCase().startsWith('fe80:')) {
      return text;
    }
    final scope = ByteData.sublistView(bytes).getUint32(24, Endian.host);
    return scope == 0 ? text : '$text%$scope';
  }
  return null;
}

String _prefixOriginName(NL_PREFIX_ORIGIN origin) => switch (origin) {
  IpPrefixOriginManual => 'Manual',
  IpPrefixOriginDhcp => 'Dhcp',
  IpPrefixOriginRouterAdvertisement => 'RouterAdvertisement',
  IpPrefixOriginWellKnown => 'WellKnown',
  _ => 'Other',
};

String _operationalStatusName(IF_OPER_STATUS status) => switch (status) {
  IfOperStatusUp => 'Up',
  IfOperStatusDown => 'Disconnected',
  IfOperStatusDormant => 'Dormant',
  IfOperStatusNotPresent => 'Not present',
  IfOperStatusLowerLayerDown => 'Lower layer down',
  IfOperStatusTesting => 'Testing',
  _ => 'Unknown',
};

String _formatLinkSpeed(int bitsPerSecond) {
  if (bitsPerSecond <= 0) return '';
  if (bitsPerSecond >= 1000000000) {
    final value = bitsPerSecond / 1000000000;
    return '${value == value.roundToDouble() ? value.toInt() : value.toStringAsFixed(1)} Gbps';
  }
  if (bitsPerSecond >= 1000000) {
    final value = bitsPerSecond / 1000000;
    return '${value == value.roundToDouble() ? value.toInt() : value.toStringAsFixed(1)} Mbps';
  }
  if (bitsPerSecond >= 1000) {
    return '${(bitsPerSecond / 1000).toStringAsFixed(0)} Kbps';
  }
  return '$bitsPerSecond bps';
}
