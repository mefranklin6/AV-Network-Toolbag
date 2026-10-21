import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'dart_dhcp_server.dart';
import 'dhcp_firewall_lease.dart';
import 'models.dart';
import 'scan_range.dart';
import 'update_service.dart';
import 'windows_adapter_api.dart';
import 'windows_network_probe.dart';
import 'windows_save_dialog.dart';

class BackendException implements Exception {
  const BackendException(this.message);
  final String message;

  @override
  String toString() => message;
}

abstract interface class NetworkBackend {
  Future<Map<String, dynamic>> initialize();
  Future<List<AdapterSummary>> listAdapters({bool inspectHyperV = false});
  Future<AdapterDetails> getAdapterDetails(
    String interfaceAlias, {
    bool inspectHyperV = false,
  });
  Future<AdapterDiagnostics> getAdapterDiagnostics(AdapterDetails details);
  Future<bool> isAddressInUse(String interfaceAlias, String address);
  Future<void> setStatic(
    String interfaceAlias,
    String address,
    int prefixLength,
  );
  Future<void> setDhcp(String interfaceAlias);
  Future<void> setLinkLocal(String interfaceAlias);
  Future<ScanPlan> getScanPlan(String interfaceAlias);
  Future<void> startScan(String interfaceAlias);
  Future<ScanStatus> getScanStatus();
  Future<void> cancelScan();
  Future<String?> exportScanCsv();
  Future<DhcpDefaults> getDhcpDefaults(String interfaceAlias);
  Future<DhcpState> getDhcpState();
  Future<DhcpState> startDhcpServer(Map<String, dynamic> configuration);
  Future<DhcpState> stopDhcpServer();
  Future<void> setTheme(String theme);
  Future<void> close();
}

/// Native Windows backend.
///
/// Adapter reads use IP Helper through Dart FFI. Long-running work is made of
/// cancellable Dart futures. Subnet scans use native ICMP worker isolates;
/// configuration and individual safety checks use bounded Windows utilities.
/// PowerShell is never loaded.
class WindowsNetworkBackend implements NetworkBackend {
  final Map<String, WindowsAdapterInfo> _adapters = {};
  _ScanState? _scan;
  DartDhcpServer? _dhcpServer;
  DhcpFirewallLease? _dhcpFirewallRule;
  Future<DhcpState>? _dhcpStart;
  Future<void>? _closeFuture;
  bool _closed = false;

  Directory get _firewallJournalDirectory => Directory(
    '${_settingsFile.parent.path}${Platform.pathSeparator}firewall-rules',
  );

  File get _settingsFile {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    final base = localAppData == null || localAppData.isEmpty
        ? Directory.systemTemp.path
        : localAppData;
    return File(
      '$base${Platform.pathSeparator}AVNetworkToolbag'
      '${Platform.pathSeparator}settings.json',
    );
  }

  @override
  Future<Map<String, dynamic>> initialize() async {
    if (!Platform.isWindows) {
      throw const BackendException(
        'AV Network Toolbag currently supports Windows only.',
      );
    }
    await DhcpFirewallLease.recover(
      _firewallJournalDirectory,
      _deleteDhcpFirewallRule,
    );
    final settings = await _loadSettings();
    return {
      'admin': true,
      'theme': _themeFromSettings(settings),
      'version': readExecutableVersion(),
    };
  }

  Future<void> _refreshAdapterCache() async {
    _ensureOpen();
    final snapshots = await Isolate.run(queryWindowsAdapters).timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw const BackendException(
        'Windows did not return the network adapter table within 10 seconds.',
      ),
    );
    _adapters
      ..clear()
      ..addEntries(
        snapshots
            .map(WindowsAdapterInfo.fromMap)
            .where((adapter) => adapter.alias.isNotEmpty)
            .map((adapter) => MapEntry(adapter.alias, adapter)),
      );
  }

  @override
  Future<List<AdapterSummary>> listAdapters({
    bool inspectHyperV = false,
  }) async {
    await _refreshAdapterCache();
    final hyperVAdapterMacs = _hyperVAdapterMacs();
    return _adapters.values.map((adapter) {
      final context = _adapterContext(
        adapter,
        hyperVAdapterMacs: hyperVAdapterMacs,
      );
      return AdapterSummary(
        alias: adapter.alias,
        description: adapter.description,
        status: adapter.status,
        macAddress: adapter.macAddress,
        linkSpeed: adapter.linkSpeed,
        interfaceIndex: adapter.interfaceIndex,
        adapterType: context.adapterType,
        canConfigure: context.canConfigure,
        isSwitchUplink: context.isSwitchUplink,
        notice: context.notice,
      );
    }).toList();
  }

  @override
  Future<AdapterDetails> getAdapterDetails(
    String interfaceAlias, {
    bool inspectHyperV = false,
  }) async {
    var adapter = _adapters[interfaceAlias];
    if (adapter == null) {
      await _refreshAdapterCache();
      adapter = _adapters[interfaceAlias];
    }
    if (adapter == null) {
      throw BackendException(
        "Network adapter '$interfaceAlias' was not found.",
      );
    }
    final context = _adapterContext(
      adapter,
      hyperVAdapterMacs: _hyperVAdapterMacs(),
    );
    final ipv4 = adapter.ipv4
        .map(
          (value) => Ipv4AddressInfo(
            address: value['address']! as String,
            prefixLength: value['prefixLength']! as int,
            subnetMask: value['subnetMask']! as String,
            origin: value['origin']! as String,
          ),
        )
        .toList();
    return AdapterDetails(
      alias: adapter.alias,
      interfaceIndex: adapter.interfaceIndex,
      description: adapter.description,
      status: adapter.status,
      macAddress: adapter.macAddress,
      linkSpeed: adapter.linkSpeed,
      adapterType: context.adapterType,
      canConfigure: context.canConfigure,
      notice: context.notice,
      ipv4: ipv4,
      ipv6: adapter.ipv6,
      internet: false,
      dns: false,
      dhcp: ipv4.isEmpty
          ? const DhcpDetection(
              kind: StatusKind.neutral,
              label: 'No IPv4',
              detail: 'The adapter has no IPv4 address.',
            )
          : const DhcpDetection(
              kind: StatusKind.pending,
              label: 'Checking…',
              detail: 'DHCP discovery is running in the background.',
            ),
    );
  }

  @override
  Future<AdapterDiagnostics> getAdapterDiagnostics(
    AdapterDetails details,
  ) async {
    final address = details.primaryIpv4;
    final adapter = _adapters[details.alias];
    if (address == null || adapter == null) {
      return const AdapterDiagnostics(
        internet: false,
        dns: false,
        dhcp: DhcpDetection(
          kind: StatusKind.neutral,
          label: 'No IPv4',
          detail: 'The adapter has no IPv4 address.',
        ),
        error: '',
      );
    }

    final connectivity = await Future.wait<bool>([
      _probeInternet(address.address),
      _probeDns(address.address, adapter.dnsServers),
    ]);
    DhcpDetection dhcp;
    final localServer = _dhcpServer;
    final localServerIsActive =
        localServer?.isRunning == true &&
        localServer?.configuration.adapterAlias == details.alias;
    final hasDhcpAddress = adapter.ipv4.any((item) => item['origin'] == 'Dhcp');
    if (localServerIsActive) {
      dhcp = DhcpDetection(
        kind: StatusKind.success,
        label: 'This tool',
        detail: 'AV Network Toolbag is serving DHCP on ${details.alias}.',
      );
    } else if (adapter.dhcpEnabled &&
        hasDhcpAddress &&
        isValidIpv4(adapter.dhcpServer) &&
        adapter.dhcpServer != '0.0.0.0') {
      dhcp = DhcpDetection(
        kind: StatusKind.success,
        label: 'External server',
        detail:
            'Windows reports an active DHCP lease from '
            '${adapter.dhcpServer}.',
      );
    } else {
      try {
        final server = await discoverDhcpServer(address.address);
        dhcp = server == null
            ? const DhcpDetection(
                kind: StatusKind.neutral,
                label: 'No server',
                detail: 'No DHCP server answered the discovery probe.',
              )
            : DhcpDetection(
                kind: StatusKind.success,
                label: 'External server',
                detail: 'A DHCP server answered at $server.',
              );
      } on Object catch (error) {
        dhcp = DhcpDetection(
          kind: StatusKind.warning,
          label: 'Not tested',
          detail: 'The DHCP discovery socket could not be opened: $error',
        );
      }
    }
    return AdapterDiagnostics(
      internet: connectivity[0],
      dns: connectivity[1],
      dhcp: dhcp,
      error: '',
    );
  }

  Future<bool> _probeInternet(String sourceAddress) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        '1.1.1.1',
        443,
        sourceAddress: InternetAddress(sourceAddress),
        timeout: const Duration(seconds: 2),
      );
      return true;
    } on Object {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  Future<bool> _probeDns(String sourceAddress, List<String> dnsServers) async {
    final server = dnsServers.where(isValidIpv4).firstOrNull;
    if (server == null) return false;
    RawDatagramSocket? socket;
    StreamSubscription<RawSocketEvent>? subscription;
    final result = Completer<bool>();
    final id = Random.secure().nextInt(0xffff);
    try {
      socket = await RawDatagramSocket.bind(InternetAddress(sourceAddress), 0);
      subscription = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? datagram;
        while ((datagram = socket!.receive()) != null) {
          final bytes = datagram!.data;
          if (bytes.length < 12) continue;
          final responseId = (bytes[0] << 8) | bytes[1];
          final response = bytes[2] & 0x80 != 0;
          final responseCode = bytes[3] & 0x0f;
          final answers = (bytes[6] << 8) | bytes[7];
          if (responseId == id && response && !result.isCompleted) {
            result.complete(responseCode == 0 && answers > 0);
          }
        }
      });
      socket.send(
        _dnsQuery(id, 'www.cloudflare.com'),
        InternetAddress(server),
        53,
      );
      return await result.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => false,
      );
    } on Object {
      return false;
    } finally {
      if (subscription != null) await subscription.cancel();
      socket?.close();
    }
  }

  @override
  Future<bool> isAddressInUse(String interfaceAlias, String address) async {
    if (!isValidIpv4(address)) {
      throw const BackendException('Enter a valid IPv4 address.');
    }
    final adapter = await _requireAdapter(interfaceAlias);
    final source = adapter.ipv4.firstOrNull?['address'] as String?;
    return _ping(address, sourceAddress: source, timeoutMilliseconds: 1000);
  }

  @override
  Future<void> setStatic(
    String interfaceAlias,
    String address,
    int prefixLength,
  ) async {
    if (!isValidIpv4(address)) {
      throw const BackendException('Enter a valid IPv4 address.');
    }
    final adapter = await _requireConfigurableAdapter(interfaceAlias);
    await _runWindowsCommand('netsh.exe', [
      'interface',
      'ipv4',
      'set',
      'address',
      'name=${adapter.interfaceIndex}',
      'source=static',
      'address=$address',
      'mask=${prefixToSubnetMask(prefixLength)}',
      'gateway=none',
      'store=persistent',
    ], failurePrefix: 'Windows could not set the static IPv4 address.');
    _adapters.clear();
  }

  @override
  Future<void> setDhcp(String interfaceAlias) async {
    final adapter = await _requireConfigurableAdapter(interfaceAlias);
    await _runWindowsCommand('netsh.exe', [
      'interface',
      'ipv4',
      'set',
      'address',
      'name=${adapter.interfaceIndex}',
      'source=dhcp',
    ], failurePrefix: 'Windows could not enable automatic IPv4 addressing.');
    await _runWindowsCommand('netsh.exe', [
      'interface',
      'ipv4',
      'set',
      'dnsservers',
      'name=${adapter.interfaceIndex}',
      'source=dhcp',
    ], failurePrefix: 'Windows could not enable automatic DNS settings.');
    _adapters.clear();
  }

  @override
  Future<void> setLinkLocal(String interfaceAlias) async {
    final adapter = await _requireConfigurableAdapter(interfaceAlias);
    String? candidate;
    final random = Random.secure();
    for (var attempt = 0; attempt < 30; attempt++) {
      final address =
          '169.254.${random.nextInt(254) + 1}.'
          '${random.nextInt(254) + 1}';
      if (!await _ping(address, timeoutMilliseconds: 500)) {
        candidate = address;
        break;
      }
    }
    if (candidate == null) {
      throw const BackendException(
        'Unable to find an unused link-local address after 30 attempts.',
      );
    }
    await _runWindowsCommand('netsh.exe', [
      'interface',
      'ipv4',
      'set',
      'address',
      'name=${adapter.interfaceIndex}',
      'source=static',
      'address=$candidate',
      'mask=255.255.0.0',
      'gateway=none',
      'store=persistent',
    ], failurePrefix: 'Windows could not set the link-local address.');
    _adapters.clear();
  }

  @override
  Future<ScanPlan> getScanPlan(String interfaceAlias) async {
    final adapter = await _requireAdapter(interfaceAlias);
    final ipv4 = adapter.ipv4.firstOrNull;
    if (ipv4 == null) {
      throw const BackendException(
        'The selected adapter does not have an IPv4 subnet to scan.',
      );
    }
    final address = ipv4['address']! as String;
    final prefix = ipv4['prefixLength']! as int;
    final blockSize = 1 << (32 - prefix);
    final network = ipv4ToInt(address) & (~(blockSize - 1) & 0xffffffff);
    final first = prefix <= 30 ? network + 1 : network;
    final last = prefix <= 30
        ? network + blockSize - 2
        : network + blockSize - 1;
    validateScanSize(last - first + 1);
    return ScanPlan(
      interfaceAlias: interfaceAlias,
      networkAddress: intToIpv4(network),
      prefixLength: prefix,
      hostCount: last - first + 1,
    );
  }

  @override
  Future<void> startScan(String interfaceAlias) async {
    if (_scan != null && !_scan!.complete) {
      throw const BackendException('A subnet scan is already running.');
    }
    final adapter = await _requireAdapter(interfaceAlias);
    final ipv4 = adapter.ipv4.firstOrNull;
    if (ipv4 == null) {
      throw const BackendException(
        'The selected adapter does not have an IPv4 subnet to scan.',
      );
    }
    final address = ipv4['address']! as String;
    final prefix = ipv4['prefixLength']! as int;
    final blockSize = 1 << (32 - prefix);
    final network = ipv4ToInt(address) & (~(blockSize - 1) & 0xffffffff);
    final first = prefix <= 30 ? network + 1 : network;
    final last = prefix <= 30
        ? network + blockSize - 2
        : network + blockSize - 1;
    validateScanSize(last - first + 1);
    final scan = _ScanState();
    _scan = scan;
    unawaited(
      _runScan(
        scan,
        first: first,
        last: last,
        sourceAddress: address,
        interfaceIndex: adapter.interfaceIndex,
        localMacAddress: adapter.macAddress,
      ),
    );
  }

  Future<void> _runScan(
    _ScanState scan, {
    required int first,
    required int last,
    required String sourceAddress,
    required int interfaceIndex,
    required String localMacAddress,
  }) async {
    final active = <String>[];
    final macs = <String, String>{};
    try {
      await _runNativePingSweep(
        scan,
        first: first,
        last: last,
        sourceAddress: sourceAddress,
        interfaceIndex: interfaceIndex,
        active: active,
        macs: macs,
      );

      scan.status = 'Gathering host details for ${active.length} active hosts…';
      active.sort((left, right) => ipv4ToInt(left).compareTo(ipv4ToInt(right)));
      macs.addAll(queryWindowsIpv4Neighbors(interfaceIndex));
      final hostnames = await _runNativeHostnameLookups(scan, active);
      final results = [
        for (final address in active)
          ScanResult(
            ipAddress: address,
            hostname: hostnames[address] ?? '(no PTR record)',
            macAddress: address == sourceAddress
                ? localMacAddress
                : macs[address] ?? '(unavailable)',
          ),
      ];
      scan
        ..results = List.unmodifiable(results)
        ..progress = 100
        ..status = 'Complete: ${results.length} active hosts found'
        ..complete = true;
    } on _ScanCancelled {
      scan
        ..cancelled = true
        ..status = 'Scan cancelled.'
        ..complete = true;
    } on Object catch (error) {
      scan
        ..error = error.toString()
        ..status = 'The scan could not be completed.'
        ..complete = true;
    }
  }

  Future<void> _runNativePingSweep(
    _ScanState scan, {
    required int first,
    required int last,
    required String sourceAddress,
    required int interfaceIndex,
    required List<String> active,
    required Map<String, String> macs,
  }) async {
    const workerCount = 8;
    const timeoutMilliseconds = 500;
    final total = last - first + 1;

    final resultPort = ReceivePort();
    final controls = <int, SendPort>{};
    final workers = <Isolate>[];
    final finished = Completer<void>();
    var completedWorkers = 0;
    var processed = 0;
    var nextNeighborSnapshot = 128;
    String? workerError;
    var stopSent = false;

    late final StreamSubscription<Object?> subscription;
    subscription = resultPort.listen((message) {
      if (message is! List || message.isEmpty) return;
      switch (message[0]) {
        case 'ready':
          final id = message[1] as int;
          final control = message[2] as SendPort;
          controls[id] = control;
          if (stopSent) control.send('stop');
        case 'result':
          processed++;
          if (message[2] == true) active.add(message[1] as String);
          if (processed == total || processed % 8 == 0) {
            scan
              ..activeCount = active.length
              ..progress = min(70, ((processed / total) * 70).round())
              ..status =
                  'Ping scan: $processed of $total checked; '
                  '${active.length} active';
          }
        case 'error':
          workerError ??= message[2]?.toString() ?? 'Native ICMP scan failed.';
        case 'done':
          completedWorkers++;
          if (completedWorkers == workerCount && !finished.isCompleted) {
            finished.complete();
          }
      }
    });

    try {
      for (var index = 0; index < workerCount; index++) {
        workers.add(
          await Isolate.spawn(windowsIcmpScanWorker, {
            'resultPort': resultPort.sendPort,
            'workerId': index,
            'sourceAddress': sourceAddress,
            'first': first + index,
            'last': last,
            'stride': workerCount,
            'timeoutMilliseconds': timeoutMilliseconds,
          }),
        );
      }

      while (!finished.isCompleted) {
        await Future.any([
          finished.future,
          Future<void>.delayed(const Duration(milliseconds: 150)),
        ]);
        if (processed >= nextNeighborSnapshot) {
          macs.addAll(queryWindowsIpv4Neighbors(interfaceIndex));
          nextNeighborSnapshot = processed + 128;
        }
        if (scan.cancelRequested && !stopSent) {
          stopSent = true;
          for (final control in controls.values) {
            control.send('stop');
          }
        }
      }
      if (workerError != null) throw BackendException(workerError!);
      if (scan.cancelRequested) throw const _ScanCancelled();
    } finally {
      await subscription.cancel();
      resultPort.close();
      for (final worker in workers) {
        worker.kill(priority: Isolate.immediate);
      }
    }
  }

  Future<Map<String, String>> _runNativeHostnameLookups(
    _ScanState scan,
    List<String> addresses,
  ) async {
    if (addresses.isEmpty) return const {};
    const maximumWorkers = 8;
    final workerCount = min(maximumWorkers, addresses.length);
    final groups = List.generate(workerCount, (_) => <String>[]);
    for (var index = 0; index < addresses.length; index++) {
      groups[index % workerCount].add(addresses[index]);
    }

    final resultPort = ReceivePort();
    final controls = <int, SendPort>{};
    final workers = <Isolate>[];
    final hostnames = <String, String>{};
    final finished = Completer<void>();
    var completedWorkers = 0;
    var processed = 0;
    String? workerError;
    var stopSent = false;

    late final StreamSubscription<Object?> subscription;
    subscription = resultPort.listen((message) {
      if (message is! List || message.isEmpty) return;
      switch (message[0]) {
        case 'ready':
          final id = message[1] as int;
          final control = message[2] as SendPort;
          controls[id] = control;
          if (stopSent) control.send('stop');
        case 'hostname':
          hostnames[message[1] as String] = message[2] as String;
          processed++;
          scan
            ..progress = 70 + ((processed / addresses.length) * 30).round()
            ..status =
                'Hostname lookup: $processed of '
                '${addresses.length} complete';
        case 'error':
          workerError ??= message[2]?.toString() ?? 'Hostname lookup failed.';
        case 'done':
          completedWorkers++;
          if (completedWorkers == groups.length && !finished.isCompleted) {
            finished.complete();
          }
      }
    });

    try {
      for (var index = 0; index < groups.length; index++) {
        workers.add(
          await Isolate.spawn(windowsHostnameWorker, {
            'resultPort': resultPort.sendPort,
            'workerId': index,
            'addresses': groups[index],
          }),
        );
      }

      while (!finished.isCompleted) {
        await Future.any([
          finished.future,
          Future<void>.delayed(const Duration(milliseconds: 150)),
        ]);
        if (scan.cancelRequested && !stopSent) {
          stopSent = true;
          for (final control in controls.values) {
            control.send('stop');
          }
        }
      }
      if (workerError != null) throw BackendException(workerError!);
      if (scan.cancelRequested) throw const _ScanCancelled();
      return hostnames;
    } finally {
      await subscription.cancel();
      resultPort.close();
      for (final worker in workers) {
        worker.kill(priority: Isolate.immediate);
      }
    }
  }

  @override
  Future<ScanStatus> getScanStatus() async {
    final scan = _scan;
    if (scan == null) {
      throw const BackendException('No subnet scan has been started.');
    }
    return scan.toModel();
  }

  @override
  Future<void> cancelScan() async {
    _scan?.cancelRequested = true;
  }

  @override
  Future<String?> exportScanCsv() async {
    final scan = _scan;
    if (scan == null || !scan.complete) {
      throw const BackendException(
        'Complete a subnet scan before exporting it.',
      );
    }
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final name =
        'subnet-scan-${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}.csv';
    final path = showCsvSaveDialog(name);
    if (path == null) return null;
    final output = StringBuffer(
      '\ufeff"IP Address","Hostname","MAC Address"\r\n',
    );
    for (final result in scan.results) {
      output.writeln(
        '${_csv(result.ipAddress)},${_csv(result.hostname)},'
        '${_csv(result.macAddress)}',
      );
    }
    await File(path).writeAsString(output.toString());
    return path;
  }

  @override
  Future<DhcpDefaults> getDhcpDefaults(String interfaceAlias) async {
    final settings = await _dhcpAdapterSettings(interfaceAlias);
    final serverValue = ipv4ToInt(settings.address);
    final blockSize = 1 << (32 - settings.prefixLength);
    final network = serverValue & (~(blockSize - 1) & 0xffffffff);
    final broadcast = network + blockSize - 1;
    final segments = <(int, int)>[];
    if (serverValue > network + 1) segments.add((network + 1, serverValue - 1));
    if (serverValue < broadcast - 1) {
      segments.add((serverValue + 1, broadcast - 1));
    }
    if (segments.isEmpty) {
      throw const BackendException(
        'This subnet has no usable client addresses outside the server address.',
      );
    }
    final preferred = network + 100;
    segments.sort((left, right) {
      final leftPreferred = preferred >= left.$1 && preferred <= left.$2;
      final rightPreferred = preferred >= right.$1 && preferred <= right.$2;
      if (leftPreferred != rightPreferred) return leftPreferred ? -1 : 1;
      return (right.$2 - right.$1).compareTo(left.$2 - left.$1);
    });
    final segment = segments.first;
    final capacity = segment.$2 - segment.$1 + 1;
    final poolSize = min(20, capacity);
    final start =
        preferred >= segment.$1 && preferred + poolSize - 1 <= segment.$2
        ? preferred
        : segment.$1;
    return DhcpDefaults(
      adapterAlias: interfaceAlias,
      serverAddress: settings.address,
      prefixLength: settings.prefixLength,
      subnetMask: prefixToSubnetMask(settings.prefixLength),
      isStatic: settings.isStatic,
      poolStart: intToIpv4(start),
      poolSize: poolSize,
      maxPoolSize: min(250, capacity),
      leaseMinutes: 120,
    );
  }

  @override
  Future<DhcpState> getDhcpState() async {
    final server = _dhcpServer;
    return DhcpState(
      running: server?.isRunning ?? false,
      lastError: server?.lastError ?? '',
      configuration: server?.configuration.toMap(),
      leases: server?.leases ?? const [],
    );
  }

  @override
  Future<DhcpState> startDhcpServer(Map<String, dynamic> parameters) async {
    _ensureOpen();
    if (_dhcpStart != null || _closeFuture != null) {
      throw const BackendException(
        'DHCP startup or application shutdown is in progress.',
      );
    }
    final operation = _startDhcpServer(parameters);
    _dhcpStart = operation;
    try {
      return await operation;
    } finally {
      _dhcpStart = null;
    }
  }

  Future<DhcpState> _startDhcpServer(Map<String, dynamic> parameters) async {
    if (_dhcpServer?.isRunning == true) {
      throw const BackendException(
        'The AV Network Toolbag DHCP server is already running.',
      );
    }
    final alias = parameters['interfaceAlias'] as String? ?? '';
    final settings = await _dhcpAdapterSettings(alias);
    if (!settings.isStatic) {
      throw const BackendException(
        'The selected adapter must have a static IPv4 address before it can host DHCP.',
      );
    }
    final configuration = _validateDhcpConfiguration(parameters, settings);
    final adapter = await _requireAdapter(alias);
    final hasActiveLease =
        adapter.dhcpEnabled &&
        adapter.ipv4.any((item) => item['origin'] == 'Dhcp') &&
        isValidIpv4(adapter.dhcpServer);
    if (hasActiveLease) {
      throw BackendException(
        'An existing DHCP server is reported at ${adapter.dhcpServer}.',
      );
    }
    try {
      final detected = await discoverDhcpServer(settings.address);
      if (detected != null) {
        throw BackendException(
          'An existing DHCP server answered at $detected.',
        );
      }
    } on BackendException {
      rethrow;
    } on Object catch (error) {
      throw BackendException(
        'The DHCP safety check could not open its discovery socket: $error',
      );
    }

    final active = <String>[];
    final addresses = configuration.poolAddresses;
    for (var offset = 0; offset < addresses.length; offset += 12) {
      final group = addresses.sublist(
        offset,
        min(offset + 12, addresses.length),
      );
      final replies = await Future.wait(
        group.map(
          (address) => _ping(
            address,
            sourceAddress: settings.address,
            timeoutMilliseconds: 700,
          ),
        ),
      );
      for (var index = 0; index < replies.length; index++) {
        if (replies[index]) active.add(group[index]);
      }
    }
    if (active.isNotEmpty) {
      throw BackendException(
        'The proposed pool contains addresses that replied to ping: '
        '${active.join(', ')}',
      );
    }

    final rule =
        'AVNetworkToolbag-Dart-$pid-${DateTime.now().microsecondsSinceEpoch}';
    await _removeDhcpFirewallRule();
    _dhcpFirewallRule = await DhcpFirewallLease.acquire(
      _firewallJournalDirectory,
      rule,
    );
    try {
      // Scope by adapter, not destination IP: initial DHCP requests arrive
      // at the broadcast address before the client has an IPv4 address.
      await const MethodChannel('av_network_toolbag/firewall')
          .invokeMethod<void>('addDhcpRule', {
            'name': rule,
            'interfaceAlias': configuration.adapterAlias,
          });
      final server = DartDhcpServer(configuration);
      await server.start();
      _dhcpServer = server;
    } on Object {
      await _removeDhcpFirewallRule();
      rethrow;
    }
    return getDhcpState();
  }

  @override
  Future<DhcpState> stopDhcpServer() async {
    await _dhcpServer?.stop();
    await _removeDhcpFirewallRule();
    return getDhcpState();
  }

  Future<void> _removeDhcpFirewallRule() async {
    final rule = _dhcpFirewallRule;
    if (rule == null) return;
    await rule.release(_deleteDhcpFirewallRule);
    _dhcpFirewallRule = null;
  }

  Future<void> _deleteDhcpFirewallRule(String rule) async {
    // The native API treats an already-absent rule as success, without relying
    // on localized netsh output. Other failures preserve the recovery journal.
    await const MethodChannel('av_network_toolbag/firewall')
        .invokeMethod<void>('removeRule', rule);
  }

  @override
  Future<void> setTheme(String theme) async {
    if (!const {'Light', 'Dark', 'System'}.contains(theme)) {
      throw const BackendException('Unknown theme.');
    }
    await _saveSetting('theme', theme);
  }

  Future<Map<String, dynamic>> _loadSettings() async {
    try {
      final value = jsonDecode(await _settingsFile.readAsString());
      if (value is Map<String, dynamic>) return value;
    } on Object {
      // First run or invalid settings use defaults.
    }
    return <String, dynamic>{};
  }

  String _themeFromSettings(Map<String, dynamic> settings) {
    final theme = settings['theme'] as String?;
    return const {'Light', 'Dark', 'System'}.contains(theme) ? theme! : 'Dark';
  }

  Future<void> _saveSetting(String key, Object value) async {
    final settings = await _loadSettings();
    settings[key] = value;
    final file = _settingsFile;
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(settings));
  }

  Future<WindowsAdapterInfo> _requireAdapter(String alias) async {
    var adapter = _adapters[alias];
    if (adapter == null) {
      await _refreshAdapterCache();
      adapter = _adapters[alias];
    }
    if (adapter == null) {
      throw BackendException("Network adapter '$alias' was not found.");
    }
    return adapter;
  }

  Future<WindowsAdapterInfo> _requireConfigurableAdapter(String alias) async {
    final adapter = await _requireAdapter(alias);
    final context = _adapterContext(
      adapter,
      hyperVAdapterMacs: _hyperVAdapterMacs(),
    );
    if (!context.canConfigure) throw BackendException(context.notice);
    return adapter;
  }

  Set<String> _hyperVAdapterMacs() => _adapters.values
      .where(
        (adapter) =>
            adapter.alias.startsWith('vEthernet (') &&
            adapter.macAddress.isNotEmpty,
      )
      .map((adapter) => adapter.macAddress)
      .toSet();

  Future<_DhcpAdapterSettings> _dhcpAdapterSettings(String alias) async {
    final adapter = await _requireConfigurableAdapter(alias);
    if (adapter.status != 'Up') {
      throw BackendException(
        'The selected adapter is ${adapter.status}. Connect it before enabling the DHCP server.',
      );
    }
    final address = adapter.ipv4
        .where((value) => (value['prefixLength']! as int) <= 30)
        .firstOrNull;
    if (address == null) {
      throw const BackendException(
        'The selected adapter needs an IPv4 address with a /30 or larger subnet.',
      );
    }
    return _DhcpAdapterSettings(
      address: address['address']! as String,
      prefixLength: address['prefixLength']! as int,
      isStatic: address['origin'] == 'Manual' && !adapter.dhcpEnabled,
    );
  }

  DhcpServerConfiguration _validateDhcpConfiguration(
    Map<String, dynamic> parameters,
    _DhcpAdapterSettings settings,
  ) {
    final poolStart = parameters['poolStart'] as String? ?? '';
    final poolSize = parameters['poolSize'] as int? ?? 0;
    final leaseMinutes = parameters['leaseMinutes'] as int? ?? 0;
    if (!isValidIpv4(poolStart)) {
      throw const BackendException(
        'Enter a valid IPv4 address for the pool start.',
      );
    }
    if (poolSize < 1 || poolSize > 250) {
      throw const BackendException('Pool size must be between 1 and 250.');
    }
    if (leaseMinutes < 1 || leaseMinutes > 10080) {
      throw const BackendException(
        'Lease time must be between 1 minute and 7 days.',
      );
    }
    final serverValue = ipv4ToInt(settings.address);
    final blockSize = 1 << (32 - settings.prefixLength);
    final network = serverValue & (~(blockSize - 1) & 0xffffffff);
    final broadcast = network + blockSize - 1;
    final start = ipv4ToInt(poolStart);
    final end = start + poolSize - 1;
    if (start <= network || end >= broadcast || end < start) {
      throw BackendException(
        'The complete pool must be inside ${intToIpv4(network)}/'
        '${settings.prefixLength}, excluding network and broadcast addresses.',
      );
    }
    if (serverValue >= start && serverValue <= end) {
      throw const BackendException(
        "The pool includes this computer's address.",
      );
    }
    final router = (parameters['router'] as String? ?? '').trim();
    if (router.isNotEmpty && !isValidIpv4(router)) {
      throw const BackendException(
        'Enter a valid router address or leave it blank.',
      );
    }
    if (router.isNotEmpty) {
      final value = ipv4ToInt(router);
      if (value <= network || value >= broadcast) {
        throw const BackendException(
          'The router must be on the selected subnet.',
        );
      }
    }
    final dns = _parseIpv4List(
      parameters['dnsServers'] as String? ?? '',
      'DNS servers',
    );
    final ntp = _parseIpv4List(
      parameters['ntpServers'] as String? ?? '',
      'NTP servers',
    );
    for (final reserved in [
      router,
      ...dns,
      ...ntp,
    ].where((value) => value.isNotEmpty)) {
      final value = ipv4ToInt(reserved);
      if (value >= start && value <= end) {
        throw BackendException(
          'The pool includes configured infrastructure address $reserved.',
        );
      }
    }
    final domain = (parameters['domainName'] as String? ?? '').trim();
    final domainPattern = RegExp(
      r'^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$',
    );
    if (domain.length > 253 ||
        (domain.isNotEmpty && !domainPattern.hasMatch(domain))) {
      throw const BackendException(
        'The domain name may contain letters, numbers, periods, and hyphens, and cannot begin or end with punctuation.',
      );
    }
    return DhcpServerConfiguration(
      adapterAlias: parameters['interfaceAlias'] as String? ?? '',
      interfaceIndex: _adapters[parameters['interfaceAlias']]!.interfaceIndex,
      serverAddress: settings.address,
      prefixLength: settings.prefixLength,
      subnetMask: prefixToSubnetMask(settings.prefixLength),
      poolStart: poolStart,
      poolSize: poolSize,
      leaseMinutes: leaseMinutes,
      router: router,
      dnsServers: dns,
      ntpServers: ntp,
      domainName: domain,
    );
  }

  List<String> _parseIpv4List(String input, String label) {
    final result = <String>[];
    for (final value
        in input.split(RegExp(r'[,;\s]+')).where((item) => item.isNotEmpty)) {
      if (!isValidIpv4(value)) {
        throw BackendException(
          '$label contains an invalid IPv4 address: $value',
        );
      }
      if (!result.contains(value)) result.add(value);
    }
    if (result.length > 31) {
      throw BackendException('$label can contain at most 31 addresses.');
    }
    return result;
  }

  Future<bool> _ping(
    String address, {
    String? sourceAddress,
    int timeoutMilliseconds = 700,
  }) async {
    final arguments = <String>[
      if (sourceAddress != null && sourceAddress.isNotEmpty) ...[
        '-S',
        sourceAddress,
      ],
      '-n',
      '1',
      '-w',
      timeoutMilliseconds.toString(),
      address,
    ];
    try {
      final result = await _runWindowsCommand(
        'ping.exe',
        arguments,
        checkExitCode: false,
        timeout: Duration(milliseconds: timeoutMilliseconds + 1200),
      );
      return result.exitCode == 0;
    } on Object {
      return false;
    }
  }

  Future<_CommandResult> _runWindowsCommand(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 12),
    bool checkExitCode = true,
    String failurePrefix = 'The Windows command failed.',
  }) async {
    _ensureOpen();
    final process = await Process.start(
      executable,
      arguments,
      mode: ProcessStartMode.normal,
    );
    final stdoutBytes = BytesBuilder();
    final stderrBytes = BytesBuilder();
    final stdoutDone = process.stdout.listen(stdoutBytes.add).asFuture<void>();
    final stderrDone = process.stderr.listen(stderrBytes.add).asFuture<void>();
    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill();
      throw BackendException(
        '$executable did not finish within ${timeout.inSeconds} seconds.',
      );
    }
    await Future.wait([stdoutDone, stderrDone]);
    final output = _CommandResult(
      exitCode,
      utf8.decode(stdoutBytes.takeBytes(), allowMalformed: true).trim(),
      utf8.decode(stderrBytes.takeBytes(), allowMalformed: true).trim(),
    );
    if (checkExitCode && exitCode != 0) {
      final detail = [
        output.stderr,
        output.stdout,
      ].where((value) => value.isNotEmpty).join(' ');
      throw BackendException(
        detail.isEmpty ? failurePrefix : '$failurePrefix $detail',
      );
    }
    return output;
  }

  @override
  Future<void> close() =>
      _closeFuture ??= _closeBackend().catchError((Object error) {
        _closeFuture = null;
        throw error;
      });

  Future<void> _closeBackend() async {
    if (_closed) return;
    _scan?.cancelRequested = true;
    try {
      await _dhcpStart;
    } on Object {
      // Startup failure still needs to be followed by cleanup.
    }
    await _dhcpServer?.stop();
    await _removeDhcpFirewallRule();
    _closed = true;
  }

  void _ensureOpen() {
    if (_closed) {
      throw const BackendException('The AV Network Toolbag backend is closed.');
    }
  }
}

_AdapterContext _adapterContext(
  WindowsAdapterInfo adapter, {
  required Set<String> hyperVAdapterMacs,
}) {
  final isUplink =
      adapter.macAddress.isNotEmpty &&
      hyperVAdapterMacs.contains(adapter.macAddress) &&
      !adapter.isVirtual &&
      !adapter.ipv4Enabled &&
      !adapter.ipv6Enabled;
  if (adapter.alias.startsWith('vEthernet (')) {
    final name = adapter.alias.substring(11, adapter.alias.length - 1);
    return _AdapterContext('Hyper-V virtual switch - $name', true, false, '');
  }
  if (isUplink) {
    return const _AdapterContext(
      'Hyper-V physical switch uplink',
      false,
      true,
      'This physical adapter has IPv4 and IPv6 unbound, which indicates a Hyper-V switch uplink. Configure its vEthernet adapter instead.',
    );
  }
  return _AdapterContext(
    adapter.isVirtual ? 'Virtual network adapter' : 'Physical network adapter',
    true,
    false,
    '',
  );
}

List<int> _dnsQuery(int id, String name) {
  final bytes = <int>[
    id >> 8,
    id & 0xff,
    0x01,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
  ];
  for (final label in name.split('.')) {
    final encoded = ascii.encode(label);
    bytes
      ..add(encoded.length)
      ..addAll(encoded);
  }
  return [...bytes, 0, 0, 1, 0, 1];
}

String _csv(String value) => '"${value.replaceAll('"', '""')}"';

class _AdapterContext {
  const _AdapterContext(
    this.adapterType,
    this.canConfigure,
    this.isSwitchUplink,
    this.notice,
  );

  final String adapterType;
  final bool canConfigure;
  final bool isSwitchUplink;
  final String notice;
}

class _DhcpAdapterSettings {
  const _DhcpAdapterSettings({
    required this.address,
    required this.prefixLength,
    required this.isStatic,
  });

  final String address;
  final int prefixLength;
  final bool isStatic;
}

class _CommandResult {
  const _CommandResult(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;
}

class _ScanState {
  int progress = 0;
  String status = 'Starting ping scan…';
  int activeCount = 0;
  bool complete = false;
  bool cancelled = false;
  bool cancelRequested = false;
  String error = '';
  List<ScanResult> results = const [];

  ScanStatus toModel() => ScanStatus(
    progress: progress,
    status: status,
    activeCount: activeCount,
    complete: complete,
    cancelled: cancelled,
    error: error,
    results: results,
  );
}

class _ScanCancelled implements Exception {
  const _ScanCancelled();
}
