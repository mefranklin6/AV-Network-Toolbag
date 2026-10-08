import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'backend_service.dart';
import 'common_widgets.dart';
import 'dhcp_dialog.dart';
import 'mdns_dialog.dart';
import 'models.dart';
import 'scan_dialog.dart';
import 'update_service.dart';

class NetworkHomeScreen extends StatefulWidget {
  const NetworkHomeScreen({
    super.key,
    required this.backend,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  final NetworkBackend backend;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  State<NetworkHomeScreen> createState() => _NetworkHomeScreenState();
}

class _NetworkHomeScreenState extends State<NetworkHomeScreen> {
  final _ipController = TextEditingController();
  UpdateService? _updateService;
  final Map<String, String> _capturedAddresses = {};
  List<AdapterSummary> _adapters = const [];
  AdapterDetails? _details;
  AdapterDiagnostics? _diagnostics;
  String? _selectedAlias;
  String? _error;
  bool _admin = false;
  bool _loadingAdapters = true;
  bool _loadingDetails = false;
  bool _loadingDiagnostics = false;
  bool _busy = false;
  bool _hideUplinks = false;
  bool _checkingForUpdate = false;
  String _appVersion = '0.0.0';
  UpdateRelease? _availableUpdate;
  int _prefixLength = 24;
  int _adapterRequest = 0;
  int _detailRequest = 0;

  @override
  void initState() {
    super.initState();
    if (widget.backend is WindowsNetworkBackend) {
      _updateService = UpdateService();
    }
    _ipController.addListener(() {
      final alias = _selectedAlias;
      if (alias != null) _capturedAddresses[alias] = _ipController.text;
      setState(() {});
    });
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _ipController.dispose();
    _updateService?.close();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      final initialization = await widget.backend.initialize();
      if (!mounted) return;
      _admin = initialization['admin'] as bool? ?? false;
      _appVersion = initialization['version'] as String? ?? '0.0.0';
      final savedTheme = initialization['theme'] as String? ?? 'Dark';
      widget.onThemeModeChanged(_themeModeFromString(savedTheme));
      if (widget.backend is WindowsNetworkBackend) {
        unawaited(_checkForUpdates(silent: true));
      }
      await _refreshAdapters();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loadingAdapters = false;
      });
    }
  }

  ThemeMode _themeModeFromString(String value) => switch (value) {
    'Light' => ThemeMode.light,
    'System' => ThemeMode.system,
    _ => ThemeMode.dark,
  };

  String _themeModeName(ThemeMode mode) => switch (mode) {
    ThemeMode.light => 'Light',
    ThemeMode.system => 'System',
    ThemeMode.dark => 'Dark',
  };

  Future<void> _setTheme(ThemeMode mode) async {
    widget.onThemeModeChanged(mode);
    try {
      await widget.backend.setTheme(_themeModeName(mode));
    } on Object catch (error) {
      if (mounted) _showMessage('Theme preference could not be saved: $error');
    }
  }

  void _cycleTheme() {
    final next = switch (widget.themeMode) {
      ThemeMode.dark => ThemeMode.light,
      ThemeMode.light => ThemeMode.system,
      ThemeMode.system => ThemeMode.dark,
    };
    unawaited(_setTheme(next));
  }

  Future<void> _checkForUpdates({required bool silent}) async {
    if (_checkingForUpdate) return;
    final updateService = _updateService;
    if (updateService == null) {
      if (!silent && mounted) _showMessage('Updates are available on Windows.');
      return;
    }
    setState(() => _checkingForUpdate = true);
    try {
      final release = await updateService.checkForUpdate(_appVersion);
      if (!mounted) return;
      setState(() => _availableUpdate = release);
      if (!silent) {
        if (release == null) {
          _showMessage('AV Network Toolbag $_appVersion is up to date.');
        } else {
          await _showUpdateAvailable(release);
        }
      }
    } on Object catch (error) {
      if (!silent && mounted) {
        _showMessage('Could not check for updates: $error');
      }
    } finally {
      if (mounted) setState(() => _checkingForUpdate = false);
    }
  }

  Future<void> _openUpdater() async {
    final release = _availableUpdate;
    if (release != null) {
      await _showUpdateAvailable(release);
    } else {
      await _checkForUpdates(silent: false);
    }
  }

  Future<void> _showUpdateAvailable(UpdateRelease release) async {
    final install = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.system_update_alt),
        title: Text('${release.name} is available'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620, maxHeight: 460),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Installed: $_appVersion   Latest: ${release.version}'),
                if (release.notes.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  SelectableText(release.notes),
                ],
                const SizedBox(height: 18),
                const Text(
                  'The release ZIP will be downloaded from GitHub, verified '
                  'against SHA256SUMS.txt, and installed after the app closes.',
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Later'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.download_for_offline_outlined),
            label: const Text('Download and restart'),
          ),
        ],
      ),
    );
    if (install == true && mounted) await _downloadAndInstall(release);
  }

  Future<void> _downloadAndInstall(UpdateRelease release) async {
    final updateService = _updateService;
    if (updateService == null) return;
    double? progress;
    var activity = 'Preparing update…';
    var dialogOpen = true;
    BuildContext? progressContext;
    StateSetter? updateDialog;
    final redraw = Stopwatch()..start();
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          progressContext = context;
          return StatefulBuilder(
            builder: (context, setDialogState) {
              updateDialog = setDialogState;
              return PopScope(
                canPop: false,
                child: AlertDialog(
                  icon: const Icon(Icons.downloading_rounded),
                  title: const Text('Downloading update'),
                  content: SizedBox(
                    width: 480,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Semantics(liveRegion: true, child: Text(activity)),
                        const SizedBox(height: 16),
                        LinearProgressIndicator(value: progress),
                        if (progress != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            '${(progress! * 100).clamp(0, 100).toStringAsFixed(0)}%',
                            textAlign: TextAlign.end,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ).whenComplete(() => dialogOpen = false),
    );
    await Future<void>.delayed(Duration.zero);

    try {
      final prepared = await updateService.prepareUpdate(
        release,
        onProgress: (value, message) {
          progress = value;
          activity = message;
          if (!dialogOpen || updateDialog == null) return;
          if (value == null ||
              value >= 1 ||
              redraw.elapsedMilliseconds >= 100) {
            redraw.reset();
            updateDialog!(() {});
          }
        },
      );
      if (!mounted) return;
      if (dialogOpen && progressContext?.mounted == true) {
        Navigator.pop(progressContext!);
      }
      await updateService.launchInstaller(prepared);
      try {
        await widget.backend.close();
      } finally {
        exit(0);
      }
    } on Object catch (error) {
      if (dialogOpen && progressContext?.mounted == true) {
        Navigator.pop(progressContext!);
      }
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            icon: Icon(
              Icons.error_outline,
              color: Theme.of(context).colorScheme.error,
            ),
            title: const Text('Update failed'),
            content: SelectableText(error.toString()),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      }
    }
  }

  List<AdapterSummary> get _visibleAdapters => _hideUplinks
      ? _adapters.where((adapter) => !adapter.isSwitchUplink).toList()
      : _adapters;

  Future<void> _refreshAdapters() async {
    final request = ++_adapterRequest;
    final inspectHyperV = _hideUplinks;
    setState(() {
      _loadingAdapters = true;
      _error = null;
    });
    try {
      final adapters = await widget.backend.listAdapters(
        inspectHyperV: inspectHyperV,
      );
      if (!mounted || request != _adapterRequest) return;
      final availableAdapters = inspectHyperV
          ? adapters.where((adapter) => !adapter.isSwitchUplink).toList()
          : adapters;
      var selection = _selectedAlias;
      if (!availableAdapters.any((adapter) => adapter.alias == selection)) {
        final preferred = availableAdapters.where(
          (adapter) => adapter.canConfigure && adapter.status == 'Up',
        );
        final configurable = availableAdapters.where(
          (adapter) => adapter.canConfigure,
        );
        selection = availableAdapters.isEmpty
            ? null
            : (preferred.firstOrNull ??
                      configurable.firstOrNull ??
                      availableAdapters.first)
                  .alias;
      }
      setState(() {
        _adapters = adapters;
        _selectedAlias = selection;
        _loadingAdapters = false;
      });
      if (selection != null) await _selectAdapter(selection, force: true);
    } on Object catch (error) {
      if (!mounted || request != _adapterRequest) return;
      setState(() {
        if (inspectHyperV) {
          _hideUplinks = false;
        }
        _error = error.toString();
        _loadingAdapters = false;
      });
    }
  }

  Future<void> _selectAdapter(String alias, {bool force = false}) async {
    if (!force && alias == _selectedAlias && _details != null) return;
    final request = ++_detailRequest;
    setState(() {
      _selectedAlias = alias;
      _details = null;
      _diagnostics = null;
      _loadingDetails = true;
      _loadingDiagnostics = false;
      _error = null;
    });
    _ipController.text = _capturedAddresses[alias] ?? '';
    try {
      final details = await widget.backend.getAdapterDetails(
        alias,
        inspectHyperV: _hideUplinks,
      );
      if (!mounted || request != _detailRequest) return;
      setState(() {
        _details = details;
        _prefixLength = details.primaryIpv4?.prefixLength ?? 24;
        _loadingDetails = false;
        _loadingDiagnostics = details.primaryIpv4 != null;
      });
      if (details.primaryIpv4 != null) {
        unawaited(_loadDiagnostics(details, request));
      }
    } on Object catch (error) {
      if (!mounted || request != _detailRequest) return;
      setState(() {
        _error = error.toString();
        _loadingDetails = false;
      });
    }
  }

  Future<void> _loadDiagnostics(AdapterDetails details, int request) async {
    try {
      final diagnostics = await widget.backend.getAdapterDiagnostics(details);
      if (!mounted || request != _detailRequest) return;
      setState(() {
        _diagnostics = diagnostics;
        _loadingDiagnostics = false;
      });
    } on Object catch (error) {
      if (!mounted || request != _detailRequest) return;
      setState(() {
        _diagnostics = AdapterDiagnostics(
          internet: false,
          dns: false,
          dhcp: DhcpDetection(
            kind: StatusKind.error,
            label: 'Unable to check',
            detail: error.toString(),
          ),
          error: error.toString(),
        );
        _loadingDiagnostics = false;
      });
    }
  }

  Future<void> _reloadDetails() async {
    final alias = _selectedAlias;
    if (alias != null) await _selectAdapter(alias, force: true);
  }

  Future<void> _runAdapterAction(
    String activity,
    Future<void> Function() action,
  ) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (!mounted) return;
      _showMessage(activity);
      await Future<void>.delayed(const Duration(milliseconds: 450));
      await _reloadDetails();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _validIpv4(String value) {
    final parts = value.trim().split('.');
    if (parts.length != 4) return false;
    return parts.every((part) {
      final number = int.tryParse(part);
      return number != null &&
          number >= 0 &&
          number <= 255 &&
          number.toString() == part.replaceFirst(RegExp(r'^0+(?=\d)'), '');
    });
  }

  void _captureCurrentAddress() {
    final address = _details?.primaryIpv4;
    if (address == null) {
      _showMessage('This adapter does not currently have an IPv4 address.');
      return;
    }
    _ipController.text = address.address;
    setState(() => _prefixLength = address.prefixLength);
    _showMessage('Captured ${address.address}/${address.prefixLength}.');
  }

  Future<void> _setStatic() async {
    final alias = _selectedAlias;
    final address = _ipController.text.trim();
    if (alias == null || !_validIpv4(address)) return;
    final alreadyAssigned =
        _details?.ipv4.any((item) => item.address == address) ?? false;
    if (!alreadyAssigned) {
      setState(() => _busy = true);
      try {
        final inUse = await widget.backend.isAddressInUse(alias, address);
        if (inUse && mounted) {
          final confirmed = await _confirm(
            title: 'Possible IP address conflict',
            message:
                '$address replied to ping and may already be in use by another device. Assign it anyway?',
            confirmLabel: 'Assign anyway',
            destructive: true,
          );
          if (!confirmed) return;
        }
      } on Object catch (error) {
        if (mounted) setState(() => _error = error.toString());
        return;
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }
    await _runAdapterAction(
      'Static IPv4 set to $address/$_prefixLength.',
      () => widget.backend.setStatic(alias, address, _prefixLength),
    );
  }

  Future<void> _setAutomatic() async {
    final alias = _selectedAlias;
    if (alias == null) return;
    final confirmed = await _confirm(
      title: 'Use automatic IPv4 addressing?',
      message:
          'Windows will discard the current static IPv4 configuration on $alias and request an address using DHCP.',
      confirmLabel: 'Use automatic addressing',
    );
    if (confirmed) {
      await _runAdapterAction(
        'Automatic IPv4 addressing enabled.',
        () => widget.backend.setDhcp(alias),
      );
    }
  }

  Future<void> _setLinkLocal() async {
    final alias = _selectedAlias;
    if (alias == null) return;
    final confirmed = await _confirm(
      title: 'Generate a link-local address?',
      message:
          'AV Network Toolbag will find an unused 169.254.x.x address and replace the current IPv4 configuration on $alias.',
      confirmLabel: 'Generate address',
    );
    if (confirmed) {
      await _runAdapterAction(
        'Link-local IPv4 address configured.',
        () => widget.backend.setLinkLocal(alias),
      );
    }
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: Icon(
            destructive
                ? Icons.warning_amber_rounded
                : Icons.help_outline_rounded,
          ),
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: destructive
                  ? FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                    )
                  : null,
              onPressed: () => Navigator.pop(context, true),
              child: Text(confirmLabel),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _openScan() async {
    final alias = _selectedAlias;
    if (alias == null) return;
    setState(() => _busy = true);
    try {
      final plan = await widget.backend.getScanPlan(alias);
      if (!mounted) return;
      final large = plan.prefixLength < 24;
      final confirmed = await _confirm(
        title: 'Scan ${plan.networkAddress}/${plan.prefixLength}?',
        message:
            'The scan will ping ${plan.hostCount} possible host addresses, then resolve names for addresses that reply.${large ? '\n\nThis is larger than a /24 and can generate substantial network traffic.' : ''}',
        confirmLabel: 'Start scan',
        destructive: large,
      );
      if (!confirmed) return;
      await widget.backend.startScan(alias);
      if (!mounted) return;
      // Starting the scan is the end of the home screen's busy operation. The
      // scan dialog owns progress from here; leaving this true keeps an
      // indeterminate progress animation running behind the dialog.
      setState(() => _busy = false);
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => SubnetScanDialog(backend: widget.backend, plan: plan),
      );
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openDhcpServer() async {
    final alias = _selectedAlias;
    if (alias == null) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          DhcpServerDialog(backend: widget.backend, interfaceAlias: alias),
    );
    if (mounted) await _reloadDetails();
  }

  Future<void> _openMdnsListener() async {
    final details = _details;
    if (details == null) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => MdnsListenerDialog(adapter: details),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f5): _refreshAdapters,
        const SingleActivator(LogicalKeyboardKey.keyD, control: true):
            _cycleTheme,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                _buildHeader(context),
                if (_busy)
                  Semantics(
                    liveRegion: true,
                    label: 'Network operation in progress',
                    child: LinearProgressIndicator(),
                  ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final wide = constraints.maxWidth >= 940;
                      final compact =
                          Theme.of(context).visualDensity.vertical < 0;
                      return Padding(
                        padding: EdgeInsets.fromLTRB(
                          compact ? 12 : (wide ? 24 : 16),
                          compact ? 10 : 18,
                          compact ? 12 : (wide ? 24 : 16),
                          compact ? 12 : 20,
                        ),
                        child: wide
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  SizedBox(
                                    width: 286,
                                    child: _buildAdapterSidebar(context),
                                  ),
                                  const SizedBox(width: 18),
                                  Expanded(
                                    child: _buildContent(
                                      context,
                                      includeCompactPicker: false,
                                    ),
                                  ),
                                ],
                              )
                            : _buildContent(
                                context,
                                includeCompactPicker: true,
                              ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 560;
        final compact = constraints.maxWidth < 900;
        final themeIcon = widget.themeMode == ThemeMode.light
            ? Icons.light_mode_outlined
            : widget.themeMode == ThemeMode.dark
            ? Icons.dark_mode_outlined
            : Icons.brightness_auto_outlined;
        final adminMessage = _admin
            ? 'Running with permission to change network settings'
            : 'Restart the app as administrator to change network settings';
        final logo = Semantics(
          label: 'AV Network Toolbag logo',
          child: Container(
            width: compact ? 38 : 46,
            height: compact ? 38 : 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.primary,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'AV',
              style: TextStyle(
                color: scheme.onPrimary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        );
        final title = Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'AV Network Toolbag',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!compact)
                Text(
                  'Windows Network Tools for the AV Technician',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
            ],
          ),
        );
        final themeAction = PopupMenuButton<ThemeMode>(
          tooltip: 'Choose appearance (Ctrl+D)',
          onSelected: (mode) => unawaited(_setTheme(mode)),
          itemBuilder: (context) => const [
            PopupMenuItem(value: ThemeMode.light, child: Text('Light theme')),
            PopupMenuItem(value: ThemeMode.dark, child: Text('Dark theme')),
            PopupMenuItem(
              value: ThemeMode.system,
              child: Text('Use system theme'),
            ),
          ],
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(themeIcon),
                if (!compact) ...[
                  const SizedBox(width: 8),
                  Text(_themeModeName(widget.themeMode)),
                  const Icon(Icons.arrow_drop_down),
                ],
              ],
            ),
          ),
        );
        final updateAction = Badge(
          isLabelVisible: _availableUpdate != null,
          child: _checkingForUpdate
              ? Semantics(
                  liveRegion: true,
                  label: 'Checking for updates',
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                    ),
                  ),
                )
              : IconButton(
                  tooltip: _availableUpdate == null
                      ? 'Check for updates'
                      : 'Version ${_availableUpdate!.version} is available',
                  onPressed: _openUpdater,
                  icon: Icon(
                    _availableUpdate == null
                        ? Icons.system_update_outlined
                        : Icons.system_update_alt,
                  ),
                ),
        );
        final adminAction = Tooltip(
          message: adminMessage,
          child: compact
              ? Semantics(
                  label: _admin ? 'Administrator' : 'Read only',
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Icon(
                      _admin
                          ? Icons.verified_user_outlined
                          : Icons.lock_outline,
                    ),
                  ),
                )
              : Chip(
                  avatar: Icon(
                    _admin ? Icons.verified_user_outlined : Icons.lock_outline,
                    size: 18,
                  ),
                  label: Text(_admin ? 'Administrator' : 'Read only'),
                  side: BorderSide.none,
                ),
        );
        final actions = <Widget>[
          themeAction,
          const SizedBox(width: 8),
          updateAction,
          const SizedBox(width: 8),
          adminAction,
        ];
        return Container(
          color: scheme.surfaceContainerLow,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : 24,
            vertical: compact ? 8 : 14,
          ),
          child: narrow
              ? Column(
                  children: [
                    Row(children: [logo, const SizedBox(width: 14), title]),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: actions,
                    ),
                  ],
                )
              : Row(
                  children: [
                    logo,
                    const SizedBox(width: 14),
                    title,
                    ...actions,
                  ],
                ),
        );
      },
    );
  }

  Widget _buildAdapterSidebar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final adapters = _visibleAdapters;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
              child: Text(
                'Network adapters (${adapters.length})',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                'Choose an adapter to inspect and configure.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _hideUplinks,
              onChanged: (value) => _setUplinkFilter(value ?? false),
              title: const Text('Hide Hyper-V switch uplinks'),
            ),
            const Divider(),
            Expanded(
              child: _loadingAdapters
                  ? Center(
                      child: Semantics(
                        liveRegion: true,
                        label: 'Loading network adapters',
                        child: CircularProgressIndicator(),
                      ),
                    )
                  : adapters.isEmpty
                  ? const Center(child: Text('No network adapters found.'))
                  : ListView.separated(
                      itemCount: adapters.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder: (context, index) {
                        final adapter = adapters[index];
                        final selected = adapter.alias == _selectedAlias;
                        return Semantics(
                          selected: selected,
                          button: true,
                          excludeSemantics: true,
                          onTap: () => _selectAdapter(adapter.alias),
                          label:
                              '${adapter.alias}, ${adapter.status}, ${adapter.adapterType}',
                          child: ListTile(
                            selected: selected,
                            selectedTileColor: scheme.primaryContainer,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            leading: Icon(
                              adapter.status == 'Up'
                                  ? Icons.lan_rounded
                                  : Icons.portable_wifi_off_rounded,
                              color: adapter.status == 'Up'
                                  ? (scheme.brightness == Brightness.dark
                                        ? const Color(0xFF5EE0B3)
                                        : const Color(0xFF087F5B))
                                  : scheme.onSurfaceVariant,
                            ),
                            title: Text(
                              adapter.alias,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(adapter.status, maxLines: 1),
                            onTap: () => _selectAdapter(adapter.alias),
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _loadingAdapters || _busy ? null : _refreshAdapters,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh adapters'),
            ),
          ],
        ),
      ),
    );
  }

  void _setUplinkFilter(bool value) {
    if (_hideUplinks == value) return;
    setState(() => _hideUplinks = value);
    unawaited(_refreshAdapters());
  }

  Widget _buildCompactPicker(BuildContext context) {
    final adapters = _visibleAdapters;
    final compact = Theme.of(context).visualDensity.vertical < 0;
    return Card(
      child: Padding(
        padding: EdgeInsets.all(compact ? 11 : 16),
        child: Column(
          children: [
            DropdownButtonFormField<String>(
              initialValue:
                  adapters.any((adapter) => adapter.alias == _selectedAlias)
                  ? _selectedAlias
                  : null,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Network adapter',
                prefixIcon: Icon(Icons.lan_outlined),
              ),
              items: [
                for (final adapter in adapters)
                  DropdownMenuItem(
                    value: adapter.alias,
                    child: Text('${adapter.alias} — ${adapter.status}'),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (value) => value == null ? null : _selectAdapter(value),
            ),
            Row(
              children: [
                Expanded(
                  child: CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _hideUplinks,
                    onChanged: (value) => _setUplinkFilter(value ?? false),
                    title: const Text('Hide Hyper-V uplinks'),
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh adapters (F5)',
                  onPressed: _loadingAdapters || _busy
                      ? null
                      : _refreshAdapters,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context, {
    required bool includeCompactPicker,
  }) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (includeCompactPicker) ...[
            _buildCompactPicker(context),
            const SizedBox(height: 14),
          ],
          if (!_admin) ...[
            const InlineNotice(
              message: 'AV Network Toolbag is running read-only. Restart it as administrator to change adapter settings or host DHCP.',
              error: true,
            ),
            const SizedBox(height: 14),
          ],
          if (_error != null) ...[
            InlineNotice(message: _error!, error: true),
            const SizedBox(height: 14),
          ],
          if (_selectedAlias == null && !_loadingAdapters)
            const Padding(
              padding: EdgeInsets.all(48),
              child: Center(child: Text('Select a network adapter to begin.')),
            )
          else if (_loadingDetails)
            Padding(
              padding: const EdgeInsets.all(72),
              child: Center(
                child: Semantics(
                  liveRegion: true,
                  label: 'Loading adapter details',
                  child: CircularProgressIndicator(),
                ),
              ),
            )
          else if (_details != null) ...[
            _buildStatusCards(context),
            const SizedBox(height: 14),
            _buildAddressDetails(context),
            const SizedBox(height: 14),
            _buildConfiguration(context),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusCards(BuildContext context) {
    final details = _details!;
    final diagnostics = _diagnostics;
    final diagnosticsPending =
        details.ipv4.isNotEmpty && (_loadingDiagnostics || diagnostics == null);
    final diagnosticsFailed = diagnostics?.error.isNotEmpty == true;
    final dhcpStatus = diagnostics?.dhcp ?? details.dhcp;
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 760
            ? 4
            : (constraints.maxWidth >= 430 ? 2 : 1);
        final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            SizedBox(
              width: width,
              child: StatusCard(
                label: 'Adapter',
                value: details.status,
                kind: details.status == 'Up'
                    ? StatusKind.success
                    : StatusKind.error,
              ),
            ),
            SizedBox(
              width: width,
              child: StatusCard(
                label: 'Internet',
                value: details.ipv4.isEmpty
                    ? 'No IPv4'
                    : diagnosticsPending
                    ? 'Checking...'
                    : diagnosticsFailed
                    ? 'Unable to check'
                    : (diagnostics!.internet ? 'Connected' : 'No reply'),
                kind: details.ipv4.isEmpty
                    ? StatusKind.neutral
                    : diagnosticsPending
                    ? StatusKind.pending
                    : diagnosticsFailed
                    ? StatusKind.error
                    : (diagnostics!.internet
                          ? StatusKind.success
                          : StatusKind.error),
              ),
            ),
            SizedBox(
              width: width,
              child: StatusCard(
                label: 'DNS',
                value: details.ipv4.isEmpty
                    ? 'Not tested'
                    : diagnosticsPending
                    ? 'Checking...'
                    : diagnosticsFailed
                    ? 'Unable to check'
                    : (diagnostics!.dns ? 'Working' : 'No reply'),
                kind: details.ipv4.isEmpty
                    ? StatusKind.neutral
                    : diagnosticsPending
                    ? StatusKind.pending
                    : diagnosticsFailed
                    ? StatusKind.error
                    : (diagnostics!.dns
                          ? StatusKind.success
                          : StatusKind.error),
              ),
            ),
            SizedBox(
              width: width,
              child: StatusCard(
                label: 'DHCP',
                value: dhcpStatus.label,
                kind: dhcpStatus.kind,
                tooltip: dhcpStatus.detail,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildAddressDetails(BuildContext context) {
    final details = _details!;
    return SectionCard(
      title: 'Address details',
      trailing: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          FilledButton.tonalIcon(
            onPressed: details.ipv4.isEmpty || _busy ? null : _openScan,
            icon: const Icon(Icons.radar_rounded),
            label: const Text('Scan subnet'),
          ),
          FilledButton.tonalIcon(
            onPressed: details.status != 'Up' || _busy
                ? null
                : _openMdnsListener,
            icon: const Icon(Icons.wifi_tethering),
            label: const Text('mDNS listener'),
          ),
        ],
      ),
      child: Column(
        children: [
          if (details.notice.isNotEmpty) ...[
            InlineNotice(message: details.notice),
            const SizedBox(height: 8),
          ],
          DetailRow(
            label: 'Adapter type',
            value: details.adapterType,
            monospace: false,
          ),
          const Divider(height: 1),
          DetailRow(
            label: 'Description',
            value: details.description,
            monospace: false,
          ),
          const Divider(height: 1),
          DetailRow(
            label: 'MAC address',
            value: details.macAddress.isEmpty
                ? 'Not available'
                : details.macAddress,
          ),
          const Divider(height: 1),
          DetailRow(
            label: 'IPv4 address',
            value: details.ipv4.isEmpty
                ? 'No IPv4 address'
                : details.ipv4.map((item) => item.address).join(', '),
          ),
          const Divider(height: 1),
          DetailRow(
            label: 'Prefix / mask',
            value: details.ipv4.isEmpty
                ? '—'
                : details.ipv4
                      .map(
                        (item) => '/${item.prefixLength}  (${item.subnetMask})',
                      )
                      .join(', '),
          ),
          const Divider(height: 1),
          DetailRow(
            label: 'IPv6 address',
            value: details.ipv6.isEmpty
                ? 'No IPv6 address'
                : details.ipv6.join('\n'),
          ),
        ],
      ),
    );
  }

  Widget _buildConfiguration(BuildContext context) {
    final details = _details!;
    final canChange = _admin && details.canConfigure && !_busy;
    final validAddress = _validIpv4(_ipController.text);
    return SectionCard(
      title: 'IPv4 configuration',
      child: FocusTraversalGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                // Keep all fields comfortably usable at common test/window
                // widths and when Windows text scaling increases button size.
                final narrow = constraints.maxWidth < 760;
                final addressField = TextField(
                  controller: _ipController,
                  enabled: canChange,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  decoration: InputDecoration(
                    labelText: 'IP address',
                    hintText: '192.168.1.25',
                    errorText: _ipController.text.isNotEmpty && !validAddress
                        ? 'Enter a valid IPv4 address'
                        : null,
                  ),
                );
                final prefixField = DropdownButtonFormField<int>(
                  initialValue: _prefixLength,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'CIDR prefix'),
                  selectedItemBuilder: (context) => [
                    for (var prefix = 0; prefix <= 32; prefix++)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '/$prefix  ${_prefixToMask(prefix)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  items: [
                    for (var prefix = 0; prefix <= 32; prefix++)
                      DropdownMenuItem(
                        value: prefix,
                        child: Text(
                          '/$prefix  ${_prefixToMask(prefix)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: canChange
                      ? (value) => setState(() => _prefixLength = value ?? 24)
                      : null,
                );
                final captureButton = OutlinedButton.icon(
                  onPressed: canChange && details.primaryIpv4 != null
                      ? _captureCurrentAddress
                      : null,
                  icon: const Icon(Icons.content_copy_outlined),
                  label: const Text('Capture current IPv4'),
                );
                if (narrow) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      addressField,
                      const SizedBox(height: 12),
                      prefixField,
                      const SizedBox(height: 12),
                      captureButton,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: addressField),
                    const SizedBox(width: 12),
                    Expanded(flex: 3, child: prefixField),
                    const SizedBox(width: 12),
                    captureButton,
                  ],
                );
              },
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: canChange && validAddress ? _setStatic : null,
              icon: const Icon(Icons.save_outlined),
              label: Text(
                validAddress
                    ? 'Set static IPv4 to ${_ipController.text.trim()}/$_prefixLength'
                    : 'Enter an IPv4 address',
              ),
            ),
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, constraints) {
                final buttonWidth = constraints.maxWidth >= 760
                    ? (constraints.maxWidth - 24) / 3
                    : (constraints.maxWidth >= 460
                          ? (constraints.maxWidth - 12) / 2
                          : constraints.maxWidth);
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    SizedBox(
                      width: buttonWidth,
                      child: OutlinedButton.icon(
                        onPressed: canChange ? _setAutomatic : null,
                        icon: const Icon(Icons.autorenew_rounded),
                        label: const Text('Automatic addressing (DHCP)'),
                      ),
                    ),
                    SizedBox(
                      width: buttonWidth,
                      child: OutlinedButton.icon(
                        onPressed: canChange ? _setLinkLocal : null,
                        icon: const Icon(Icons.casino_outlined),
                        label: const Text('Link Local (169.254.0.0/24)'),
                      ),
                    ),
                    SizedBox(
                      width: buttonWidth,
                      child: OutlinedButton.icon(
                        onPressed: canChange && details.ipv4.isNotEmpty
                            ? _openDhcpServer
                            : null,
                        icon: const Icon(Icons.router_outlined),
                        label: const Text('Manage DHCP Server'),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  String _prefixToMask(int prefix) {
    final octets = <int>[];
    for (var index = 0; index < 4; index++) {
      final bits = math.min(8, math.max(0, prefix - index * 8));
      octets.add(bits == 0 ? 0 : 256 - (1 << (8 - bits)));
    }
    return octets.join('.');
  }
}
