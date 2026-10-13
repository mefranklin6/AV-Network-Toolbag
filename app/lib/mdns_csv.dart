import 'dart:convert';

import 'mdns_listener.dart';

/// One row per DNS question or record, with a packet row when none were parsed.
/// Raw packet and record bytes allow inspection of types we do not decode yet.
String buildMdnsCsv(Iterable<MdnsPacket> packets) {
  const headers = [
    'Captured At (UTC)',
    'Source IP',
    'Source Port',
    'MAC Address (if known)',
    'Packet Bytes',
    'Packet Base64',
    'DNS ID',
    'DNS Flags (hex)',
    'Questions',
    'Answers',
    'Authorities',
    'Additionals',
    'Section',
    'Name',
    'Type',
    'Class',
    'Unicast/Cache Flush',
    'TTL (seconds)',
    'Decoded Data',
    'Record Data Base64',
    'Parse Error',
  ];
  final output = StringBuffer('\ufeff${headers.map(_csv).join(',')}\r\n');
  for (final packet in packets) {
    final message = inspectMdnsPacket(packet.payload);
    final prefix = [
      packet.timestamp.toUtc().toIso8601String(),
      packet.sourceAddress,
      packet.sourcePort,
      packet.macAddress,
      packet.payload.length,
      base64.encode(packet.payload),
      message.id,
      message.flags == null
          ? ''
          : '0x${message.flags!.toRadixString(16).padLeft(4, '0')}',
      message.questionCount,
      message.answerCount,
      message.authorityCount,
      message.additionalCount,
    ];
    final entries = message.entries.isEmpty
        ? <MdnsEntry?>[null]
        : message.entries;
    for (final entry in entries) {
      output.write(
        [
          ...prefix,
          entry?.section ?? '',
          entry?.name ?? '',
          entry?.type ?? '',
          entry?.dnsClass ?? '',
          entry == null ? '' : entry.unicastOrFlush,
          entry?.ttl ?? '',
          entry?.data ?? '',
          entry?.rawData ?? '',
          message.parseError,
        ].map(_csv).join(','),
      );
      output.write('\r\n');
    }
  }
  return output.toString();
}

String _csv(Object? value) =>
    '"${(value ?? '').toString().replaceAll('"', '""')}"';
