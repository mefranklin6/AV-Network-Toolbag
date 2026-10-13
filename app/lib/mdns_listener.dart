import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

typedef MdnsPacketCallback = void Function(MdnsPacket packet);
typedef MdnsStatusCallback = void Function(String status);

class MdnsPacket {
  const MdnsPacket({
    required this.macAddress,
    required this.sourceAddress,
    required this.hostnames,
    required this.advertisedAddresses,
    required this.timestamp,
    required this.sourcePort,
    required this.payload,
  });

  final String macAddress;
  final String sourceAddress;
  final Set<String> hostnames;
  final Set<String> advertisedAddresses;
  final DateTime timestamp;
  final int sourcePort;
  final Uint8List payload;
}

class MdnsListenerController {
  MdnsListenerController({
    required this.interfaceIndex,
    required this.interfaceAddresses,
    required this.onPacket,
    required this.onStatus,
  });

  final int interfaceIndex;
  final List<String> interfaceAddresses;
  final MdnsPacketCallback onPacket;
  final MdnsStatusCallback onStatus;

  final List<RawDatagramSocket> _udpSockets = [];
  final List<StreamSubscription<RawSocketEvent>> _udpSubscriptions = [];
  bool _running = false;

  bool get isRunning => _running;

  Future<void> start() async {
    if (_running) return;
    _running = true;
    await _startUdpFallback();
    onStatus(
      'Listening through native multicast. Devices are identified by source IP; MAC addresses appear when Windows already has a neighbor entry.',
    );
    unawaited(_sendDiscoveryQuery());
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    for (final subscription in _udpSubscriptions) {
      await subscription.cancel();
    }
    _udpSubscriptions.clear();
    for (final socket in _udpSockets) {
      socket.close();
    }
    _udpSockets.clear();
    onStatus('Listener stopped. Captured devices remain visible.');
  }

  Future<void> _startUdpFallback() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.any,
      includeLinkLocal: true,
    );
    NetworkInterface? selected;
    for (final interface in interfaces) {
      if (interface.index == interfaceIndex ||
          interface.addresses.any(
            (address) =>
                interfaceAddresses.contains(_withoutScope(address.address)),
          )) {
        selected = interface;
        break;
      }
    }
    if (selected == null) {
      throw StateError('The selected Windows network interface was not found.');
    }

    Object? lastError;
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        5353,
        reuseAddress: true,
      );
      socket.joinMulticast(InternetAddress('224.0.0.251'), selected);
      socket.multicastHops = 255;
      _listenTo(socket);
    } on Object catch (error) {
      lastError = error;
    }
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv6,
        5353,
        reuseAddress: true,
      );
      socket.joinMulticast(InternetAddress('ff02::fb'), selected);
      socket.multicastHops = 255;
      _listenTo(socket);
    } on Object catch (error) {
      lastError = error;
    }
    if (_udpSockets.isEmpty) {
      throw StateError(
        'Windows could not open the mDNS multicast port: $lastError',
      );
    }
  }

  void _listenTo(RawDatagramSocket socket) {
    _udpSockets.add(socket);
    _udpSubscriptions.add(
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? datagram;
        while ((datagram = socket.receive()) != null) {
          _emitPacket(
            '',
            datagram!.address.address,
            datagram.port,
            datagram.data,
          );
        }
      }),
    );
  }

  Future<void> _sendDiscoveryQuery() async {
    if (!_running) return;
    final query = _buildDiscoveryQuery();
    final source = interfaceAddresses
        .map(InternetAddress.tryParse)
        .whereType<InternetAddress>()
        .where((address) => address.type == InternetAddressType.IPv4)
        .firstOrNull;
    if (source == null) return;
    try {
      final sender = await RawDatagramSocket.bind(source, 0);
      sender.multicastHops = 255;
      _listenTo(sender);
      sender.send(query, InternetAddress('224.0.0.251'), 5353);
    } on Object {
      // Passive listening remains useful if active discovery cannot be sent.
    }
  }

  void _emitPacket(
    String mac,
    String source,
    int sourcePort,
    Uint8List payload,
  ) {
    if (!_running) return;
    final records = parseMdnsPacket(payload);
    onPacket(
      MdnsPacket(
        macAddress: mac,
        sourceAddress: _withoutScope(source),
        hostnames: records.hostnames,
        advertisedAddresses: records.addresses,
        timestamp: DateTime.now(),
        sourcePort: sourcePort,
        payload: Uint8List.fromList(payload),
      ),
    );
  }
}

class MdnsEntry {
  const MdnsEntry({
    required this.section,
    required this.name,
    required this.type,
    required this.dnsClass,
    required this.unicastOrFlush,
    this.ttl,
    this.data = '',
    this.rawData = '',
  });

  final String section;
  final String name;
  final int type;
  final int dnsClass;
  final bool unicastOrFlush;
  final int? ttl;
  final String data;
  final String rawData;
}

class MdnsMessage {
  const MdnsMessage({
    required this.id,
    required this.flags,
    required this.questionCount,
    required this.answerCount,
    required this.authorityCount,
    required this.additionalCount,
    required this.entries,
    this.parseError = '',
  });

  final int? id;
  final int? flags;
  final int? questionCount;
  final int? answerCount;
  final int? authorityCount;
  final int? additionalCount;
  final List<MdnsEntry> entries;
  final String parseError;
}

/// Parses every DNS section while preserving the raw packet if a field is bad.
MdnsMessage inspectMdnsPacket(Uint8List bytes) {
  if (bytes.length < 12) {
    return const MdnsMessage(
      id: null,
      flags: null,
      questionCount: null,
      answerCount: null,
      authorityCount: null,
      additionalCount: null,
      entries: [],
      parseError: 'Truncated DNS header',
    );
  }
  final view = ByteData.sublistView(bytes);
  final counts = [
    for (final offset in [4, 6, 8, 10]) view.getUint16(offset),
  ];
  final entries = <MdnsEntry>[];
  var offset = 12;
  var error = '';
  try {
    for (var section = 0; section < 4; section++) {
      for (var index = 0; index < counts[section]; index++) {
        final owner = _readDnsName(bytes, offset);
        offset = owner.nextOffset;
        if (offset + (section == 0 ? 4 : 10) > bytes.length) {
          throw const FormatException('Truncated DNS entry');
        }
        final type = view.getUint16(offset);
        final classBits = view.getUint16(offset + 2);
        offset += 4;
        if (section == 0) {
          entries.add(
            MdnsEntry(
              section: 'question',
              name: owner.value,
              type: type,
              dnsClass: classBits & 0x7fff,
              unicastOrFlush: classBits & 0x8000 != 0,
            ),
          );
          continue;
        }
        final ttl = view.getUint32(offset);
        final length = view.getUint16(offset + 4);
        offset += 6;
        final end = offset + length;
        if (end > bytes.length) {
          throw const FormatException('Truncated record data');
        }
        final raw = bytes.sublist(offset, end);
        String decoded;
        try {
          decoded = _decodeRecord(bytes, offset, end, type);
        } on Object {
          decoded = '';
        }
        entries.add(
          MdnsEntry(
            section: const [
              'question',
              'answer',
              'authority',
              'additional',
            ][section],
            name: owner.value,
            type: type,
            dnsClass: classBits & 0x7fff,
            unicastOrFlush: classBits & 0x8000 != 0,
            ttl: ttl,
            data: decoded,
            rawData: base64.encode(raw),
          ),
        );
        offset = end;
      }
    }
  } on Object catch (exception) {
    error = exception.toString();
  }
  if (error.isEmpty && offset != bytes.length) {
    error = 'Trailing ${bytes.length - offset} bytes';
  }
  return MdnsMessage(
    id: view.getUint16(0),
    flags: view.getUint16(2),
    questionCount: counts[0],
    answerCount: counts[1],
    authorityCount: counts[2],
    additionalCount: counts[3],
    entries: entries,
    parseError: error,
  );
}

String _decodeRecord(Uint8List bytes, int start, int end, int type) {
  if (type == 1 && end - start == 4) return bytes.sublist(start, end).join('.');
  if (type == 28 && end - start == 16) {
    return InternetAddress.fromRawAddress(bytes.sublist(start, end)).address;
  }
  if (type == 12 || type == 5 || type == 2 || type == 39) {
    final name = _readDnsName(bytes, start);
    if (name.nextOffset > end) throw const FormatException();
    return name.value;
  }
  if (type == 33 && end - start >= 6) {
    final view = ByteData.sublistView(bytes);
    final target = _readDnsName(bytes, start + 6);
    if (target.nextOffset > end) throw const FormatException();
    return 'priority=${view.getUint16(start)}; weight=${view.getUint16(start + 2)}; '
        'port=${view.getUint16(start + 4)}; target=${target.value}';
  }
  if (type == 16) {
    final values = <String>[];
    var offset = start;
    while (offset < end) {
      final length = bytes[offset++];
      if (offset + length > end) throw const FormatException();
      values.add(
        utf8.decode(
          bytes.sublist(offset, offset + length),
          allowMalformed: true,
        ),
      );
      offset += length;
    }
    return jsonEncode(values);
  }
  return '';
}

class MdnsRecords {
  const MdnsRecords({required this.hostnames, required this.addresses});

  final Set<String> hostnames;
  final Set<String> addresses;
}

MdnsRecords parseMdnsPacket(Uint8List bytes) {
  final hostnames = <String>{};
  final addresses = <String>{};
  if (bytes.length < 12) {
    return MdnsRecords(hostnames: hostnames, addresses: addresses);
  }
  try {
    final data = ByteData.sublistView(bytes);
    final questions = data.getUint16(4);
    final recordCount =
        data.getUint16(6) + data.getUint16(8) + data.getUint16(10);
    var offset = 12;
    for (var index = 0; index < questions; index++) {
      final name = _readDnsName(bytes, offset);
      offset = name.nextOffset + 4;
      if (offset > bytes.length) throw const FormatException();
    }
    for (var index = 0; index < recordCount; index++) {
      final owner = _readDnsName(bytes, offset);
      offset = owner.nextOffset;
      if (offset + 10 > bytes.length) throw const FormatException();
      final type = data.getUint16(offset);
      final length = data.getUint16(offset + 8);
      final valueOffset = offset + 10;
      final end = valueOffset + length;
      if (end > bytes.length) throw const FormatException();

      if (type == 1 && length == 4) {
        final address = bytes.sublist(valueOffset, end).join('.');
        addresses.add(address);
        if (_looksLikeHostname(owner.value)) hostnames.add(owner.value);
      } else if (type == 28 && length == 16) {
        addresses.add(
          _withoutScope(
            InternetAddress.fromRawAddress(
              Uint8List.fromList(bytes.sublist(valueOffset, end)),
            ).address,
          ),
        );
        if (_looksLikeHostname(owner.value)) hostnames.add(owner.value);
      } else if (type == 12) {
        final target = _readDnsName(bytes, valueOffset).value;
        if (_looksLikeHostname(target)) hostnames.add(target);
      } else if (type == 33 && length >= 6) {
        final target = _readDnsName(bytes, valueOffset + 6).value;
        if (_looksLikeHostname(target)) hostnames.add(target);
      }
      offset = end;
    }
  } on Object {
    // Malformed multicast packets are ignored without interrupting capture.
  }
  return MdnsRecords(hostnames: hostnames, addresses: addresses);
}

({String value, int nextOffset}) _readDnsName(Uint8List bytes, int start) {
  final labels = <String>[];
  final visited = <int>{};
  var position = start;
  var nextOffset = start;
  var jumped = false;
  while (position < bytes.length && visited.add(position)) {
    final length = bytes[position];
    if (length == 0) {
      if (!jumped) nextOffset = position + 1;
      return (value: labels.join('.'), nextOffset: nextOffset);
    }
    if ((length & 0xc0) == 0xc0) {
      if (position + 1 >= bytes.length) throw const FormatException();
      final target = ((length & 0x3f) << 8) | bytes[position + 1];
      if (!jumped) nextOffset = position + 2;
      jumped = true;
      position = target;
      continue;
    }
    if ((length & 0xc0) != 0 || position + 1 + length > bytes.length) {
      throw const FormatException();
    }
    labels.add(
      String.fromCharCodes(bytes.sublist(position + 1, position + 1 + length)),
    );
    position += length + 1;
    if (!jumped) nextOffset = position;
  }
  throw const FormatException();
}

bool _looksLikeHostname(String value) {
  final lower = value.toLowerCase();
  if (lower.isEmpty || lower.startsWith('_')) return false;
  return lower.endsWith('.local') ||
      !lower.contains('._tcp.') && !lower.contains('._udp.');
}

Uint8List _buildDiscoveryQuery() {
  const names = [
    '_services._dns-sd._udp.local',
    '_workstation._tcp.local',
    '_device-info._tcp.local',
  ];
  final output = BytesBuilder(copy: false);
  final header = ByteData(12)..setUint16(4, names.length);
  output.add(header.buffer.asUint8List());
  for (final name in names) {
    for (final label in name.split('.')) {
      final encoded = label.codeUnits;
      output.addByte(encoded.length);
      output.add(encoded);
    }
    output
      ..addByte(0)
      ..add([0, 12, 0, 1]);
  }
  return output.takeBytes();
}

String _withoutScope(String address) => address.split('%').first;
