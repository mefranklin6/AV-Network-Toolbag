import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:av_network_toolbag/backend_service.dart';
import 'package:av_network_toolbag/hidden_adapters.dart';
import 'package:av_network_toolbag/main.dart';
import 'package:av_network_toolbag/models.dart';
import 'package:av_network_toolbag/ipv4_presets.dart';
import 'package:av_network_toolbag/ipv4_presets_dialog.dart';

void main() {
  testWidgets('manage, rename, recall and delete an IPv4 preset', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _MemoryPresetStore();
    final backend = _FakeBackend();
    await tester.pumpWidget(
      AvNetworkToolbagApp(backend: backend, presetStore: store),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'IP address'),
      '10.42.0.10',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ipv4-presets-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manage presets').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add preset'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a preset name'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Preset name'),
      'Stage',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(store.presets.single.name, 'Stage');
    expect(
      tester.getCenter(find.text('10.42.0.10/24')).dy,
      tester.getCenter(find.text('Rename')).dy,
    );
    expect(
      tester.getCenter(find.text('10.42.0.10/24')).dy,
      tester.getCenter(find.text('Delete')).dy,
    );
    await tester.tap(find.text('Open JSON'));
    await tester.pumpAndSettle();
    expect(store.revealCalls, 1);
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Preset name'),
      'Stage renamed',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(store.presets.single.name, 'Stage renamed');
    expect(store.presets.single.address, '10.42.0.10');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    // Load a different prefix so recall must update both the field and state.
    store.presets = [
      const Ipv4Preset(name: 'Stage', address: '10.42.0.10', prefixLength: 16),
    ];
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      AvNetworkToolbagApp(backend: backend, presetStore: store),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ipv4-presets-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stage (10.42.0.10/16)'));
    await tester.pumpAndSettle();
    expect(find.text('Set static IPv4 to 10.42.0.10/16'), findsOneWidget);
    expect(
      tester
          .widget<DropdownButtonFormField<int>>(
            find.byType(DropdownButtonFormField<int>),
          )
          .initialValue,
      16,
    );
    expect(backend.staticCalls, 0);
    await tester.tap(find.text('Set static IPv4 to 10.42.0.10/16'));
    await tester.pumpAndSettle();
    expect(backend.staticCalls, 1);
    expect(backend.lastPrefix, 16);
    await tester.tap(find.byKey(const ValueKey('ipv4-presets-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manage presets').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    expect(store.presets, isEmpty);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(640, 900);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Presets'));
    await tester.tap(find.byKey(const ValueKey('ipv4-presets-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manage presets').last);
    await tester.pumpAndSettle();
    expect(find.text('Add preset'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('malformed presets can be revealed and reloaded after repair', (
    tester,
  ) async {
    final store = _MemoryPresetStore()
      ..loadError = const FormatException('Invalid JSON');
    await tester.pumpWidget(
      MaterialApp(
        home: Ipv4PresetsDialog(
          store: store,
          onChanged: (_) {},
          initialAddress: '',
          initialPrefix: 24,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Fix the JSON file and reload'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Add preset'),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('Open JSON'));
    await tester.pumpAndSettle();
    expect(store.revealCalls, 1);
    store.loadError = null;
    await tester.tap(find.text('Reload'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Fix the JSON file and reload'), findsNothing);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Add preset'),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('hidden adapters are marked, revealable and persist', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _MemoryHiddenAdapterStore();
    final backend = _FakeBackend();
    await tester.pumpWidget(
      AvNetworkToolbagApp(backend: backend, hiddenAdapterStore: store),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Show hidden adapters'), findsNothing);
    await tester.tap(find.byTooltip('Hide Ethernet'));
    await tester.pumpAndSettle();
    expect(store.aliases, {'ethernet'});
    expect(find.text('All network adapters are hidden.'), findsOneWidget);
    expect(find.text('Show hidden adapters (1)'), findsOneWidget);
    expect(find.text('Address details'), findsNothing);

    await tester.tap(find.text('Show hidden adapters (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Up · Hidden'), findsOneWidget);
    expect(find.textContaining('This adapter is hidden'), findsOneWidget);
    expect(find.text('Address details'), findsOneWidget);

    // A fresh launch reads the saved list and keeps the adapter hidden.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      AvNetworkToolbagApp(backend: backend, hiddenAdapterStore: store),
    );
    await tester.pumpAndSettle();
    expect(find.text('Show hidden adapters (1)'), findsOneWidget);
    expect(find.text('All network adapters are hidden.'), findsOneWidget);

    await tester.tap(find.text('Show hidden adapters (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Unhide Ethernet'));
    await tester.pumpAndSettle();
    expect(store.aliases, isEmpty);
    expect(find.textContaining('Show hidden adapters'), findsNothing);
    expect(find.byTooltip('Hide Ethernet'), findsOneWidget);
  });

  testWidgets('window exit waits for backend cleanup', (tester) async {
    final backend = _FakeBackend()..closeGate = Completer<void>();
    await tester.pumpWidget(AvNetworkToolbagApp(backend: backend));
    await tester.pumpAndSettle();
    var finished = false;
    final exit = tester.binding.handleRequestAppExit().then((value) {
      finished = true;
      return value;
    });
    await tester.pump();
    expect(backend.closeCalls, 1);
    expect(finished, isFalse);
    backend.closeGate!.complete();
    expect(await exit, AppExitResponse.exit);
  });

  testWidgets('cleanup failure cancels exit and allows retry', (tester) async {
    final backend = _FakeBackend()..closeError = StateError('denied');
    await tester.pumpWidget(AvNetworkToolbagApp(backend: backend));
    await tester.pumpAndSettle();
    expect(await tester.binding.handleRequestAppExit(), AppExitResponse.cancel);
    backend.closeError = null;
    expect(await tester.binding.handleRequestAppExit(), AppExitResponse.exit);
  });
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
  int staticCalls = 0;
  int? lastPrefix;
  Completer<void>? closeGate;
  Object? closeError;
  int closeCalls = 0;
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
  ) async {
    staticCalls++;
    lastPrefix = prefixLength;
  }

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
  Future<void> close() async {
    closeCalls++;
    if (closeError != null) throw closeError!;
    await closeGate?.future;
  }
}

class _MemoryPresetStore extends Ipv4PresetStore {
  List<Ipv4Preset> presets = [];
  Object? loadError;
  int revealCalls = 0;
  @override
  Future<List<Ipv4Preset>> load() async {
    if (loadError != null) throw loadError!;
    return List.of(presets);
  }

  @override
  Future<void> revealInExplorer() async {
    revealCalls++;
  }

  @override
  Future<void> save(List<Ipv4Preset> values) async => presets = List.of(values);
}

class _MemoryHiddenAdapterStore extends HiddenAdapterStore {
  Set<String> aliases = {};
  @override
  Future<Set<String>> load() async => {...aliases};

  @override
  Future<void> save(Set<String> values) async => aliases = {...values};
}
