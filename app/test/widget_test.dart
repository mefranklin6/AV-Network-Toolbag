import 'package:flutter_test/flutter_test.dart';

import 'package:av_network_toolbag/backend_service.dart';
import 'package:av_network_toolbag/main.dart';
import 'package:av_network_toolbag/models.dart';

void main() {
  testWidgets('shows adapter status and configuration controls', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final backend = _FakeBackend();
      await tester.pumpWidget(AvNetworkToolbagApp(backend: backend));
      await tester.pumpAndSettle();

      expect(find.text('AV Network Toolbag'), findsOneWidget);
      expect(find.textContaining('Ethernet'), findsWidgets);
      expect(find.text('Address details'), findsOneWidget);
      expect(find.text('IPv4 configuration'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'Administrator')), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });
}

class _FakeBackend implements NetworkBackend {
  @override
  Future<Map<String, dynamic>> initialize() async => {
    'admin': true,
    'theme': 'Dark',
    'version': '3.0.0',
  };

  @override
  Future<List<AdapterSummary>> listAdapters({
    bool inspectHyperV = false,
  }) async => const [
    AdapterSummary(
      alias: 'Ethernet',
      description: 'Test adapter',
      status: 'Up',
      macAddress: '00-11-22-33-44-55',
      linkSpeed: '1 Gbps',
      interfaceIndex: 7,
      adapterType: 'Physical network adapter',
      canConfigure: true,
      isSwitchUplink: false,
      notice: '',
    ),
  ];

  @override
  Future<AdapterDetails> getAdapterDetails(
    String interfaceAlias, {
    bool inspectHyperV = false,
  }) async => const AdapterDetails(
    alias: 'Ethernet',
    description: 'Test adapter',
    status: 'Up',
    macAddress: '00-11-22-33-44-55',
    linkSpeed: '1 Gbps',
    adapterType: 'Physical network adapter',
    canConfigure: true,
    notice: '',
    ipv4: [
      Ipv4AddressInfo(
        address: '192.168.1.20',
        prefixLength: 24,
        subnetMask: '255.255.255.0',
        origin: 'Manual',
      ),
    ],
    ipv6: ['fe80::1'],
    internet: true,
    dns: true,
    dhcp: DhcpDetection(
      kind: StatusKind.neutral,
      label: 'No server',
      detail: 'No DHCP server answered the discovery probe.',
    ),
  );

  @override
  Future<AdapterDiagnostics> getAdapterDiagnostics(
    AdapterDetails details,
  ) async => const AdapterDiagnostics(
    internet: true,
    dns: true,
    dhcp: DhcpDetection(
      kind: StatusKind.neutral,
      label: 'No server',
      detail: 'No DHCP server answered the discovery probe.',
    ),
    error: '',
  );

  @override
  Future<bool> isAddressInUse(String interfaceAlias, String address) async =>
      false;

  @override
  Future<void> setStatic(
    String interfaceAlias,
    String address,
    int prefixLength,
  ) async {}

  @override
  Future<void> setDhcp(String interfaceAlias) async {}

  @override
  Future<void> setLinkLocal(String interfaceAlias) async {}

  @override
  Future<ScanPlan> getScanPlan(String interfaceAlias) async => const ScanPlan(
    interfaceAlias: 'Ethernet',
    networkAddress: '192.168.1.0',
    prefixLength: 24,
    hostCount: 254,
  );

  @override
  Future<void> startScan(String interfaceAlias) async {}

  @override
  Future<ScanStatus> getScanStatus() async => const ScanStatus(
    progress: 100,
    status: 'Complete',
    activeCount: 0,
    complete: true,
    cancelled: false,
    error: '',
    results: [],
  );

  @override
  Future<void> cancelScan() async {}

  @override
  Future<String?> exportScanCsv() async => null;

  @override
  Future<DhcpDefaults> getDhcpDefaults(String interfaceAlias) async =>
      const DhcpDefaults(
        adapterAlias: 'Ethernet',
        serverAddress: '192.168.1.20',
        prefixLength: 24,
        subnetMask: '255.255.255.0',
        isStatic: true,
        poolStart: '192.168.1.100',
        poolSize: 20,
        maxPoolSize: 100,
        leaseMinutes: 120,
      );

  @override
  Future<DhcpState> getDhcpState() async => const DhcpState(
    running: false,
    lastError: '',
    configuration: null,
    leases: [],
  );

  @override
  Future<DhcpState> startDhcpServer(Map<String, dynamic> configuration) =>
      getDhcpState();

  @override
  Future<DhcpState> stopDhcpServer() => getDhcpState();

  @override
  Future<void> setTheme(String theme) async {}

  @override
  Future<void> close() async {}
}
