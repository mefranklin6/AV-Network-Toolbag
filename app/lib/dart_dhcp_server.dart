import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'models.dart';

final Set<int> _localProbeTransactions = <int>{};
const _probeMac = <int>[0x02, 0x4e, 0x49, 0x43, 0x50, 0x52];

class DhcpServerConfiguration {
  const DhcpServerConfiguration({
    required this.adapterAlias,
    required this.interfaceIndex,
    required this.serverAddress,
    required this.prefixLength,
    required this.subnetMask,
    required this.poolStart,
    required this.poolSize,
    required this.leaseMinutes,
    required this.router,
    required this.dnsServers,
    required this.ntpServers,
    required this.domainName,
  });

  final String adapterAlias;
  final int interfaceIndex;
  final String serverAddress;
  final int prefixLength;
  final String subnetMask;
  final String poolStart;
  final int poolSize;
  final int leaseMinutes;
  final String router;
  final List<String> dnsServers;
  final List<String> ntpServers;
  final String domainName;

  int get poolStartValue => ipv4ToInt(poolStart);

  List<String> get poolAddresses =>
      List.generate(poolSize, (index) => intToIpv4(poolStartValue + index));

  Map<String, dynamic> toMap() => {
    'adapterAlias': adapterAlias,
    'serverAddress': serverAddress,
    'prefixLength': prefixLength,
    'subnetMask': subnetMask,
    'poolStart': poolStart,
    'poolEnd': intToIpv4(poolStartValue + poolSize - 1),
    'poolSize': poolSize,
    'leaseMinutes': leaseMinutes,
    'router': router,
    'dnsServers': dnsServers.join(', '),
    'ntpServers': ntpServers.join(', '),
    'domainName': domainName,
  };
}

class DartDhcpServer {
  DartDhcpServer(this.configuration);

  final DhcpServerConfiguration configuration;
  final Map<String, _LeaseRecord> _leases = {};
  final Map<String, DateTime> _declinedAddresses = {};
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  String lastError = '';

  bool get isRunning => _socket != null;

  List<DhcpLease> get leases {
    final now = DateTime.now();
    for (final lease in _leases.values) {
      if (lease.expiresAt.isAfter(now)) continue;
      if (lease.status == 'Active') lease.status = 'Expired';
      if (lease.status == 'Offered') lease.status = 'Offer expired';
    }
    final values = _leases.values.toList()
      ..sort(
        (left, right) =>
            ipv4ToInt(left.address).compareTo(ipv4ToInt(right.address)),
      );
    return values.map((lease) => lease.toModel()).toList();
  }

  Future<void> start() async {
    if (isRunning) return;
    final socket = await RawDatagramSocket.bind(
      InternetAddress(configuration.serverAddress),
      67,
      reuseAddress: false,
    );
    socket.broadcastEnabled = true;
    socket.readEventsEnabled = true;
    _socket = socket;
    _subscription = socket.listen(
      (event) {
        if (event == RawSocketEvent.read) {
          Datagram? datagram;
          while ((datagram = socket.receive()) != null) {
            handlePacket(datagram!.data);
          }
        }
      },
      onError: (Object error) {
        lastError = error.toString();
      },
    );
  }

  Future<void> stop() async {
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) await subscription.cancel();
    _socket?.close();
    _socket = null;
  }

  /// Processes one client datagram. Also usable without a socket for protocol tests.
  void handlePacket(Uint8List request) {
    try {
      final packet = _DhcpPacket.tryParse(request, operation: 1);
      if (packet == null ||
          packet.hardwareType != 1 ||
          packet.hardwareLength != 6 ||
          !packet.hasValidClientMac) {
        return;
      }
      switch (packet.messageType) {
        case 1: // DHCPDISCOVER
          final address = _selectAddress(packet);
          if (address != null) {
            _send(packet, 2, address); // DHCPOFFER
            if (!_localProbeTransactions.contains(packet.transactionId)) {
              _record(packet, address, 'Offered');
            }
          }
          break;
        case 3: // DHCPREQUEST
          if (packet.serverIdentifier.isNotEmpty &&
              packet.serverIdentifier != configuration.serverAddress) {
            return;
          }
          final requested = packet.requestedAddress.isNotEmpty
              ? packet.requestedAddress
              : (packet.clientAddress.isNotEmpty
                    ? packet.clientAddress
                    : _leases[packet.clientKey]?.address ?? '');
          if (!_addressAvailableFor(requested, packet.clientKey)) {
            _send(packet, 6, '0.0.0.0'); // DHCPNAK
            return;
          }
          _record(packet, requested, 'Active');
          _send(packet, 5, requested); // DHCPACK
          break;
        case 4: // DHCPDECLINE
          final lease = _leases[packet.clientKey];
          if (packet.serverIdentifier == configuration.serverAddress &&
              lease != null &&
              packet.requestedAddress == lease.address) {
            lease.status = 'Declined';
            lease.expiresAt = DateTime.now().add(const Duration(hours: 1));
            _declinedAddresses[lease.address] = lease.expiresAt;
          }
          break;
        case 7: // DHCPRELEASE
          final lease = _leases[packet.clientKey];
          if (lease != null) {
            lease.status = 'Released';
            lease.expiresAt = DateTime.now();
          }
          break;
        case 8: // DHCPINFORM
          _send(packet, 5, '0.0.0.0');
          break;
      }
    } on Object catch (error) {
      lastError = error.toString();
    }
  }

  String? _selectAddress(_DhcpPacket packet) {
    final existing = _leases[packet.clientKey];
    if (existing != null &&
        existing.status != 'Declined' &&
        existing.expiresAt.isAfter(DateTime.now()) &&
        _addressAvailableFor(existing.address, packet.clientKey)) {
      return existing.address;
    }
    if (_addressAvailableFor(packet.requestedAddress, packet.clientKey)) {
      return packet.requestedAddress;
    }
    for (final address in configuration.poolAddresses) {
      if (_addressAvailableFor(address, packet.clientKey)) return address;
    }
    lastError = 'The DHCP address pool is exhausted.';
    return null;
  }

  bool _addressAvailableFor(String address, String clientKey) {
    if (!_inPool(address)) return false;
    final now = DateTime.now();
    _declinedAddresses.removeWhere((_, until) => !until.isAfter(now));
    if (_declinedAddresses.containsKey(address)) return false;
    return !_leases.entries.any(
      (entry) =>
          entry.key != clientKey &&
          entry.value.address == address &&
          entry.value.expiresAt.isAfter(now) &&
          entry.value.status != 'Released',
    );
  }

  bool _inPool(String address) {
    if (!isValidIpv4(address)) return false;
    final value = ipv4ToInt(address);
    return value >= configuration.poolStartValue &&
        value < configuration.poolStartValue + configuration.poolSize;
  }

  void _record(_DhcpPacket packet, String address, String status) {
    final now = DateTime.now();
    final lifetime = status == 'Offered'
        ? const Duration(minutes: 1)
        : Duration(minutes: configuration.leaseMinutes);
    _leases[packet.clientKey] = _LeaseRecord(
      address: address,
      macAddress: packet.macAddress,
      hostName: packet.hostName,
      status: status,
      leasedAt: now,
      expiresAt: now.add(lifetime),
    );
  }

  void _send(_DhcpPacket request, int messageType, String offeredAddress) {
    final socket = _socket;
    if (socket == null) return;
    final response = Uint8List(300);
    final data = ByteData.sublistView(response);
    response[0] = 2; // BOOTREPLY
    response[1] = request.hardwareType;
    response[2] = request.hardwareLength;
    data.setUint32(4, request.transactionId);
    data.setUint16(10, request.flags);
    _writeIpv4(response, 12, request.clientAddress);
    _writeIpv4(response, 16, offeredAddress);
    _writeIpv4(response, 20, configuration.serverAddress);
    response.setRange(28, 44, request.clientHardwareAddress);
    response.setRange(236, 240, const [99, 130, 83, 99]);

    final options = BytesBuilder(copy: false)
      ..add([53, 1, messageType])
      ..add([54, 4, ..._ipv4Bytes(configuration.serverAddress)]);
    if (messageType != 6) {
      options
        ..add([1, 4, ..._ipv4Bytes(configuration.subnetMask)])
        ..add(_durationOption(51, configuration.leaseMinutes * 60))
        ..add(_durationOption(58, configuration.leaseMinutes * 30))
        ..add(_durationOption(59, configuration.leaseMinutes * 52));
      if (configuration.router.isNotEmpty) {
        options.add([3, 4, ..._ipv4Bytes(configuration.router)]);
      }
      _addAddressList(options, 6, configuration.dnsServers);
      _addAddressList(options, 42, configuration.ntpServers);
      if (configuration.domainName.isNotEmpty) {
        final domain = utf8.encode(configuration.domainName);
        options.add([15, domain.length, ...domain]);
      }
    }
    options.addByte(255);
    final encodedOptions = options.takeBytes();
    final packetLength = 240 + encodedOptions.length;
    final packet =
        packetLength <= response.length ? response : Uint8List(packetLength)
          ..setRange(0, response.length, response);
    packet.setRange(240, packetLength, encodedOptions);
    final destination = request.clientAddress.isNotEmpty && request.flags == 0
        ? InternetAddress(request.clientAddress)
        : InternetAddress('255.255.255.255');
    socket.send(packet.sublist(0, packetLength), destination, 68);
  }
}

class _LeaseRecord {
  _LeaseRecord({
    required this.address,
    required this.macAddress,
    required this.hostName,
    required this.status,
    required this.leasedAt,
    required this.expiresAt,
  });

  final String address;
  final String macAddress;
  final String hostName;
  String status;
  final DateTime leasedAt;
  DateTime expiresAt;

  DhcpLease toModel() => DhcpLease(
    ipAddress: address,
    macAddress: macAddress,
    hostName: hostName,
    status: status,
    leasedAt: _formatDateTime(leasedAt),
    expiresAt: _formatDateTime(expiresAt),
  );
}

class _DhcpPacket {
  const _DhcpPacket({
    required this.hardwareType,
    required this.hardwareLength,
    required this.transactionId,
    required this.flags,
    required this.clientAddress,
    required this.clientHardwareAddress,
    required this.options,
  });

  static _DhcpPacket? tryParse(Uint8List bytes, {required int operation}) {
    if (bytes.length < 240 ||
        bytes[0] != operation ||
        bytes[236] != 99 ||
        bytes[237] != 130 ||
        bytes[238] != 83 ||
        bytes[239] != 99) {
      return null;
    }
    final hardwareLength = min(bytes[2], 16);
    final options = <int, Uint8List>{};
    var offset = 240;
    while (offset < bytes.length) {
      final code = bytes[offset++];
      if (code == 255) break;
      if (code == 0) continue;
      if (offset >= bytes.length) break;
      final length = bytes[offset++];
      if (offset + length > bytes.length) break;
      options.putIfAbsent(
        code,
        () => Uint8List.fromList(bytes.sublist(offset, offset + length)),
      );
      offset += length;
    }
    return _DhcpPacket(
      hardwareType: bytes[1],
      hardwareLength: hardwareLength,
      transactionId: ByteData.sublistView(bytes).getUint32(4),
      flags: ByteData.sublistView(bytes).getUint16(10),
      clientAddress: _readIpv4(bytes, 12),
      clientHardwareAddress: Uint8List.fromList(bytes.sublist(28, 44)),
      options: options,
    );
  }

  final int hardwareType;
  final int hardwareLength;
  final int transactionId;
  final int flags;
  final String clientAddress;
  final Uint8List clientHardwareAddress;
  final Map<int, Uint8List> options;

  int get messageType => options[53]?.firstOrNull ?? 0;

  String get requestedAddress => _optionIpv4(50);

  String get serverIdentifier => _optionIpv4(54);

  String get hostName {
    final value = options[12];
    return value == null ? '' : utf8.decode(value, allowMalformed: true).trim();
  }

  String get macAddress => clientHardwareAddress
      .take(hardwareLength)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join('-')
      .toUpperCase();

  bool get hasValidClientMac {
    final bytes = clientHardwareAddress.take(hardwareLength).toList();
    if (bytes.length != 6 ||
        bytes.every((byte) => byte == 0) ||
        bytes.every((byte) => byte == 0xff)) {
      return false;
    }
    return bytes.first & 1 == 0;
  }

  String get clientKey {
    final identifier = options[61];
    if (identifier != null && identifier.isNotEmpty) {
      return base64Encode(identifier);
    }
    return macAddress;
  }

  String _optionIpv4(int code) {
    final value = options[code];
    return value == null || value.length < 4 ? '' : value.take(4).join('.');
  }
}

Future<String?> discoverDhcpServer(
  String sourceAddress, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  RawDatagramSocket? socket;
  StreamSubscription<RawSocketEvent>? subscription;
  final response = Completer<String?>();
  int? transactionId;
  try {
    socket = await RawDatagramSocket.bind(
      InternetAddress(sourceAddress),
      68,
      reuseAddress: true,
    );
    socket.broadcastEnabled = true;
    transactionId = Random.secure().nextInt(0x7fffffff);
    _localProbeTransactions.add(transactionId);
    subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = socket!.receive()) != null) {
        final server = dhcpDiscoveryResponse(
          datagram!.data,
          transactionId: transactionId!,
          sourceAddress: datagram.address.address,
          sourcePort: datagram.port,
        );
        if (server != null && !response.isCompleted) {
          response.complete(server);
        }
      }
    });
    socket.send(
      _buildDhcpDiscover(transactionId),
      InternetAddress('255.255.255.255'),
      67,
    );
    return await response.future.timeout(timeout, onTimeout: () => null);
  } finally {
    if (transactionId != null) {
      _localProbeTransactions.remove(transactionId);
    }
    if (subscription != null) await subscription.cancel();
    socket?.close();
  }
}

/// Recognizes only replies to this application's discovery probe.
String? dhcpDiscoveryResponse(
  Uint8List bytes, {
  required int transactionId,
  required String sourceAddress,
  required int sourcePort,
}) {
  final packet = _DhcpPacket.tryParse(bytes, operation: 2);
  if (sourcePort != 67 ||
      packet == null ||
      packet.transactionId != transactionId ||
      packet.hardwareType != 1 ||
      packet.hardwareLength != 6 ||
      (packet.messageType != 2 && packet.messageType != 5)) {
    return null;
  }
  for (var index = 0; index < _probeMac.length; index++) {
    if (packet.clientHardwareAddress[index] != _probeMac[index]) return null;
  }
  return packet.serverIdentifier.isEmpty
      ? sourceAddress
      : packet.serverIdentifier;
}

Uint8List _buildDhcpDiscover(int transactionId) {
  final bytes = Uint8List(300);
  final data = ByteData.sublistView(bytes);
  bytes[0] = 1;
  bytes[1] = 1;
  bytes[2] = 6;
  data.setUint32(4, transactionId);
  data.setUint16(10, 0x8000);
  bytes.setRange(28, 34, _probeMac);
  bytes.setRange(236, 240, const [99, 130, 83, 99]);
  final hostName = ascii.encode('AVNetworkToolbag-Probe');
  final vendorClass = ascii.encode('AVNetworkToolbag');
  final options = <int>[
    53,
    1,
    1,
    61,
    7,
    1,
    ..._probeMac,
    12,
    hostName.length,
    ...hostName,
    60,
    vendorClass.length,
    ...vendorClass,
    255,
  ];
  bytes.setRange(240, 240 + options.length, options);
  return bytes;
}

void _addAddressList(BytesBuilder options, int code, List<String> addresses) {
  if (addresses.isEmpty) return;
  final value = <int>[];
  for (final address in addresses) {
    value.addAll(_ipv4Bytes(address));
  }
  options.add([code, value.length, ...value]);
}

List<int> _durationOption(int code, int seconds) {
  final data = ByteData(4)..setUint32(0, seconds);
  return [code, 4, ...data.buffer.asUint8List()];
}

List<int> _ipv4Bytes(String address) {
  if (!isValidIpv4(address)) return const [0, 0, 0, 0];
  return address.split('.').map(int.parse).toList();
}

void _writeIpv4(Uint8List bytes, int offset, String address) {
  bytes.setRange(offset, offset + 4, _ipv4Bytes(address));
}

String _readIpv4(Uint8List bytes, int offset) {
  if (offset + 4 > bytes.length) return '';
  final value = bytes.sublist(offset, offset + 4);
  return value.every((byte) => byte == 0) ? '' : value.join('.');
}

bool isValidIpv4(String value) {
  final parts = value.split('.');
  if (parts.length != 4) return false;
  return parts.every((part) {
    final parsed = int.tryParse(part);
    return parsed != null && parsed >= 0 && parsed <= 255;
  });
}

int ipv4ToInt(String address) =>
    _ipv4Bytes(address)
        .fold<int>(0, (value, byte) => ((value << 8) | byte) & 0xffffffff);

String intToIpv4(int value) => [
  (value >> 24) & 0xff,
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
].join('.');

String _formatDateTime(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
}
