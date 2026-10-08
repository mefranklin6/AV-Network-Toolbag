import 'dart:typed_data';

import 'package:av_network_toolbag/dart_dhcp_server.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List packet(
  int type, {
  int operation = 1,
  int client = 0x52,
  String? requested,
  String? server,
}) {
  final bytes = Uint8List(300);
  bytes[0] = operation;
  bytes[1] = 1;
  bytes[2] = 6;
  ByteData.sublistView(bytes).setUint32(4, 1234);
  bytes.setRange(28, 34, [2, 0x4e, 0x49, 0x43, 0x50, client]);
  bytes.setRange(236, 240, [99, 130, 83, 99]);
  final options = [
    53,
    1,
    type,
    if (requested != null) ...[50, 4, ...requested.split('.').map(int.parse)],
    if (server != null) ...[54, 4, ...server.split('.').map(int.parse)],
    255,
  ];
  bytes.setRange(240, 240 + options.length, options);
  return bytes;
}

void main() {
  String? discover(Uint8List bytes, {int port = 67}) => dhcpDiscoveryResponse(
    bytes,
    transactionId: 1234,
    sourceAddress: '192.0.2.1',
    sourcePort: port,
  );

  test('discovery recognizes OFFER and ACK replies', () {
    for (final type in [2, 5]) {
      expect(
        discover(packet(type, operation: 2, server: '192.0.2.2')),
        '192.0.2.2',
      );
    }
    expect(discover(packet(2, operation: 2)), '192.0.2.1');
  });

  test(
    'discovery rejects requests, unrelated clients, IDs, ports and truncation',
    () {
      expect(discover(packet(2)), isNull);
      expect(discover(packet(2, operation: 2, client: 0x54)), isNull);
      final wrongId = packet(2, operation: 2);
      ByteData.sublistView(wrongId).setUint32(4, 999);
      expect(discover(wrongId), isNull);
      expect(discover(packet(2, operation: 2), port: 68), isNull);
      expect(discover(packet(6, operation: 2)), isNull);
      expect(discover(Uint8List(20)), isNull);
    },
  );

  late DartDhcpServer server;
  setUp(() {
    server = DartDhcpServer(
      const DhcpServerConfiguration(
        adapterAlias: 'test',
        interfaceIndex: 1,
        serverAddress: '192.0.2.1',
        prefixLength: 24,
        subnetMask: '255.255.255.0',
        poolStart: '192.0.2.100',
        poolSize: 3,
        leaseMinutes: 120,
        router: '',
        dnsServers: [],
        ntpServers: [],
        domainName: '',
      ),
    );
  });

  test('server ignores BOOTREPLY packets', () {
    server.handlePacket(packet(1, operation: 2));
    expect(server.leases, isEmpty);
  });

  test('declined address stays quarantined after client gets a new lease', () {
    server.handlePacket(packet(1));
    expect(server.leases.single.ipAddress, '192.0.2.100');
    server.handlePacket(
      packet(4, requested: '192.0.2.100', server: '192.0.2.1'),
    );
    server.handlePacket(packet(1, requested: '192.0.2.100'));
    expect(server.leases.single.ipAddress, '192.0.2.101');
    server.handlePacket(
      packet(3, requested: '192.0.2.100', server: '192.0.2.1'),
    );
    expect(server.leases.single.ipAddress, '192.0.2.101');
    server.handlePacket(packet(1, client: 0x54));
    expect(server.leases.map((lease) => lease.ipAddress), [
      '192.0.2.101',
      '192.0.2.102',
    ]);
  });

  test('decline must name this server and the client lease', () {
    server.handlePacket(packet(1));
    server.handlePacket(
      packet(4, requested: '192.0.2.100', server: '192.0.2.2'),
    );
    server.handlePacket(
      packet(4, requested: '192.0.2.102', server: '192.0.2.1'),
    );
    expect(server.leases.single.status, 'Offered');
  });
}
