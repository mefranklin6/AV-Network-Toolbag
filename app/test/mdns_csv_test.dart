import 'dart:convert';
import 'dart:typed_data';

import 'package:av_network_toolbag/mdns_csv.dart';
import 'package:av_network_toolbag/mdns_listener.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'exports questions, decoded records, raw bytes, and malformed packets',
    () {
      final bytes = Uint8List.fromList([
        0,
        0,
        0x84,
        0,
        0,
        1,
        0,
        2,
        0,
        0,
        0,
        0,
        4,
        0x74,
        0x65,
        0x73,
        0x74,
        5,
        0x6c,
        0x6f,
        0x63,
        0x61,
        0x6c,
        0,
        0,
        1,
        0,
        1,
        0xc0,
        0x0c,
        0,
        1,
        0x80,
        1,
        0,
        0,
        0,
        120,
        0,
        4,
        192,
        0,
        2,
        10,
        0xc0,
        0x0c,
        0,
        16,
        0,
        1,
        0,
        0,
        0,
        60,
        0,
        9,
        8,
        0x6e,
        0x61,
        0x6d,
        0x65,
        0x3d,
        0x22,
        0x78,
        0x22,
      ]);
      final message = inspectMdnsPacket(bytes);
      expect(message.parseError, isEmpty);
      expect(message.entries.map((entry) => entry.section), [
        'question',
        'answer',
        'answer',
      ]);
      expect(message.entries[1].data, '192.0.2.10');
      expect(message.entries[1].unicastOrFlush, isTrue);
      expect(message.entries[2].data, '["name=\\"x\\""]');

      MdnsPacket packet(Uint8List payload) => MdnsPacket(
        macAddress: '',
        sourceAddress: '192.0.2.1',
        sourcePort: 5353,
        hostnames: {},
        advertisedAddresses: {},
        timestamp: DateTime.utc(2026, 1, 2),
        payload: payload,
      );
      final csv = buildMdnsCsv([
        packet(bytes),
        packet(Uint8List.fromList([1])),
      ]);
      expect(csv.startsWith('\ufeff'), isTrue);
      expect(csv, contains(base64.encode(bytes)));
      expect(
        csv,
        contains('"answer","test.local","1","1","true","120","192.0.2.10"'),
      );
      expect(csv, contains('"Truncated DNS header"'));
      expect(csv, contains('name='));
    },
  );

  test('decodes service types from a real multicast response', () {
    final bytes = base64.decode(
      'AACEAAADAAUAAAAACV9zZXJ2aWNlcwdfZG5zLXNkBF91ZHAFbG9jYWwAAAwAAQxfd29ya3N0YXRpb24EX3RjcMAjAAwAAQxfZGV2aWNlLWluZm/AOwAMAAHADAAMAAEAAAAKABIPX2V4dHJvbl9zaXMtc3NowDvADAAMAAEAAAAKAA4LX2V4dHJvbl9zaXPAO8AMAAwAAQAAAAoADAlfc2Z0cC1zc2jAO8AMAAwAAQAAAAoACQZfaHR0cHPAO8AMAAwAAQAAAAoACAVfaHR0cMA7',
    );
    final message = inspectMdnsPacket(bytes);
    expect(message.parseError, isEmpty);
    expect(message.answerCount, 5);
    expect(
      message.entries.map((entry) => entry.data),
      contains('_extron_sis-ssh._tcp.local'),
    );
  });
}
