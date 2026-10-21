import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'backend_service.dart';
import 'common_widgets.dart';
import 'models.dart';

class DhcpServerDialog extends StatefulWidget {
  const DhcpServerDialog({
    super.key,
    required this.backend,
    required this.interfaceAlias,
  });

  final NetworkBackend backend;
  final String interfaceAlias;

  @override
  State<DhcpServerDialog> createState() => _DhcpServerDialogState();
}

class _DhcpServerDialogState extends State<DhcpServerDialog> {
  final _poolStart = TextEditingController();
  final _poolSize = TextEditingController(text: '20');
  final _leaseMinutes = TextEditingController(text: '120');
  final _router = TextEditingController();
  final _dns = TextEditingController();
  final _ntp = TextEditingController();
  final _domain = TextEditingController();
  final _adapterServerAddress = TextEditingController();
  final _subnetMask = TextEditingController();

  DhcpDefaults? _defaults;
  DhcpState? _state;
  Timer? _timer;
  bool _loading = true;
  bool _busy = false;
  bool _polling = false;
  bool _showAllActivity = false;
  String? _error;
  String _activity = '';

  bool get _running => _state?.running == true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final controller in [
      _poolStart,
      _poolSize,
      _leaseMinutes,
      _router,
      _dns,
      _ntp,
      _domain,
      _adapterServerAddress,
      _subnetMask,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final state = await widget.backend.getDhcpState();
      if (state.running && state.configuration != null) {
        _applyConfiguration(state.configuration!);
        if (mounted) setState(() => _state = state);
      } else {
        final defaults = await widget.backend.getDhcpDefaults(
          widget.interfaceAlias,
        );
        if (mounted) {
          setState(() {
            _state = state;
            _defaults = defaults;
            _poolStart.text = defaults.poolStart;
            _poolSize.text = defaults.poolSize.toString();
            _leaseMinutes.text = defaults.leaseMinutes.toString();
          });
        }
      }
      // Keep the adapter address live while this dialog is open. The address
      // can change outside this window (or immediately after a static IPv4
      // change), so it must not be treated as a one-time dialog default.
      await _refreshDefaults();
      _startPollingIfNeeded();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _applyConfiguration(Map<String, dynamic> configuration) {
    _poolStart.text = configuration['poolStart']?.toString() ?? '';
    _poolSize.text = configuration['poolSize']?.toString() ?? '20';
    _leaseMinutes.text = configuration['leaseMinutes']?.toString() ?? '120';
    _router.text = configuration['router']?.toString() ?? '';
    _dns.text = configuration['dnsServers']?.toString() ?? '';
    _ntp.text = configuration['ntpServers']?.toString() ?? '';
    _domain.text = configuration['domainName']?.toString() ?? '';
  }

  void _startPollingIfNeeded() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final state = await widget.backend.getDhcpState();
      if (!mounted) return;
      setState(() => _state = state);
      await _refreshDefaults();
    } on Object {
      // A transient state/defaults refresh failure should not close the
      // management UI.
    } finally {
      _polling = false;
    }
  }

  Future<void> _refreshDefaults() async {
    try {
      final defaults = await widget.backend.getDhcpDefaults(
        widget.interfaceAlias,
      );
      if (!mounted) return;
      setState(() => _defaults = defaults);
    } on Object {
      // The active server configuration can still be displayed if the
      // adapter temporarily has no usable IPv4 address.
    }
  }

  Future<void> _start() async {
    final poolSize = int.tryParse(_poolSize.text);
    final leaseMinutes = int.tryParse(_leaseMinutes.text);
    if (poolSize == null || leaseMinutes == null) {
      setState(
        () => _error = 'Pool size and lease time must be whole numbers.',
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded),
        title: const Text('Enable temporary DHCP server?'),
        content: const Text(
          'AV Network Toolbag will first check for another DHCP server and ping every proposed lease address. '
          'Only use this on a directly connected setup network that you control.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Run safety checks'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
      _activity = 'Checking for DHCP servers and addresses already in use…';
    });
    try {
      final state = await widget.backend.startDhcpServer({
        'interfaceAlias': widget.interfaceAlias,
        'poolStart': _poolStart.text.trim(),
        'poolSize': poolSize,
        'leaseMinutes': leaseMinutes,
        'router': _router.text.trim(),
        'dnsServers': _dns.text.trim(),
        'ntpServers': _ntp.text.trim(),
        'domainName': _domain.text.trim(),
      });
      if (!mounted) return;
      setState(() {
        _state = state;
        _activity = 'DHCP server is running.';
      });
      _startPollingIfNeeded();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    setState(() {
      _busy = true;
      _activity = 'Stopping DHCP and removing the temporary firewall rule…';
      _error = null;
    });
    try {
      final state = await widget.backend.stopDhcpServer();
      _timer?.cancel();
      if (mounted) {
        setState(() {
          _state = state;
          _activity = 'DHCP server stopped. Lease history remains visible for this session.';
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.sizeOf(context);
    final width = math.min(1040.0, media.width - 48);
    final height = math.min(780.0, media.height - 48);
    final scheme = Theme.of(context).colorScheme;
    final compact = Theme.of(context).visualDensity.vertical < 0;
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      label: 'Temporary DHCP Server',
      explicitChildNodes: true,
      child: Dialog(
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: width,
          height: height,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                color: scheme.surfaceContainerLow,
                padding: EdgeInsets.fromLTRB(
                  compact ? 14 : 24,
                  compact ? 11 : 20,
                  compact ? 8 : 12,
                  compact ? 10 : 18,
                ),
                child: Row(
                  children: [
                    Icon(Icons.router_rounded, color: scheme.primary, size: 34),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Temporary DHCP Server',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'For direct, temporary device setup only',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close DHCP server window',
                      onPressed: _busy ? null : () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              if (_busy)
                Semantics(
                  liveRegion: true,
                  label: 'DHCP operation in progress',
                  child: LinearProgressIndicator(),
                ),
              Expanded(
                child: _loading
                    ? Center(
                        child: Semantics(
                          liveRegion: true,
                          label: 'Loading DHCP configuration',
                          child: CircularProgressIndicator(),
                        ),
                      )
                    : SingleChildScrollView(
                        padding: EdgeInsets.all(compact ? 14 : 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_error != null) ...[
                              InlineNotice(message: _error!, error: true),
                              const SizedBox(height: 18),
                            ],
                            _buildConfiguration(context),
                            if (_activity.isNotEmpty) ...[
                              const SizedBox(height: 14),
                              Semantics(
                                liveRegion: true,
                                child: Text(_activity),
                              ),
                            ],
                            const SizedBox(height: 22),
                            _buildActions(),
                            const SizedBox(height: 26),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _showAllActivity
                                        ? 'All DHCP activity'
                                        : 'Active leases',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge,
                                  ),
                                ),
                                Tooltip(
                                  message: 'Include offers, releases, declines, and expired leases',
                                  child: SizedBox(
                                    width: 205,
                                    child: CheckboxListTile(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      controlAffinity:
                                          ListTileControlAffinity.leading,
                                      value: _showAllActivity,
                                      onChanged: (value) => setState(
                                        () => _showAllActivity = value ?? false,
                                      ),
                                      title: const Text('Show all activity'),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            _buildLeaseTable(context),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConfiguration(BuildContext context) {
    final configuration = _state?.configuration;
    final adapter =
        configuration?['adapterAlias']?.toString() ??
        _defaults?.adapterAlias ??
        widget.interfaceAlias;
    final server =
        _defaults?.serverAddress ??
        configuration?['serverAddress']?.toString() ??
        'Unavailable';
    final prefix =
        _defaults?.prefixLength.toString() ??
        configuration?['prefixLength']?.toString() ??
        '—';
    final subnet =
        _defaults?.subnetMask ??
        configuration?['subnetMask']?.toString() ??
        '—';
    final enabled = !_running && !_busy && _defaults != null;
    return FocusTraversalGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              _readOnlyField(
                'Adapter / server address',
                '$adapter  |  $server/$prefix',
                410,
                _adapterServerAddress,
              ),
              _readOnlyField('Subnet mask', subnet, 230, _subnetMask),
              _field('Pool start', _poolStart, 220, enabled: enabled),
              _field(
                'Pool size',
                _poolSize,
                150,
                enabled: enabled,
                numeric: true,
              ),
              _field(
                'Lease (minutes)',
                _leaseMinutes,
                170,
                enabled: enabled,
                numeric: true,
              ),
              _field(
                'Router / gateway (optional)',
                _router,
                270,
                enabled: enabled,
              ),
              _field(
                'DNS servers (comma-separated)',
                _dns,
                310,
                enabled: enabled,
              ),
              _field(
                'NTP servers (comma-separated)',
                _ntp,
                310,
                enabled: enabled,
              ),
              _field('Domain name (optional)', _domain, 270, enabled: enabled),
            ],
          ),
          if (_defaults?.isStatic == false) ...[
            const SizedBox(height: 14),
            const InlineNotice(
              message: 'This adapter is not using a static IPv4 address. Set a static address before enabling DHCP.',
              error: true,
            ),
          ],
        ],
      ),
    );
  }

  Widget _readOnlyField(
    String label,
    String value,
    double width,
    TextEditingController controller,
  ) {
    if (controller.text != value) {
      controller.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
    }
    return SizedBox(
      width: width,
      child: TextFormField(
        controller: controller,
        readOnly: true,
        decoration: InputDecoration(labelText: label),
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller,
    double width, {
    required bool enabled,
    bool numeric = false,
  }) => SizedBox(
    width: width,
    child: TextField(
      controller: controller,
      enabled: enabled,
      keyboardType: numeric ? TextInputType.number : TextInputType.text,
      inputFormatters: numeric
          ? [FilteringTextInputFormatter.digitsOnly]
          : null,
      decoration: InputDecoration(labelText: label),
    ),
  );

  Widget _buildActions() => Wrap(
    spacing: 12,
    runSpacing: 10,
    children: [
      if (_running)
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: _busy ? null : _stop,
          icon: const Icon(Icons.stop_circle_outlined),
          label: const Text('Stop DHCP Server'),
        )
      else
        FilledButton.icon(
          onPressed: _busy || _defaults == null || _defaults?.isStatic == false
              ? null
              : _start,
          icon: const Icon(Icons.play_circle_outline),
          label: const Text('Enable DHCP Server'),
        ),
      OutlinedButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );

  Widget _buildLeaseTable(BuildContext context) {
    final allLeases = _state?.leases ?? const <DhcpLease>[];
    final leases = _showAllActivity
        ? allLeases
        : allLeases.where((lease) => lease.status == 'Active').toList();
    if (leases.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          _showAllActivity
              ? 'No DHCP activity has been recorded yet.'
              : 'No active leases.',
        ),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: const [
          DataColumn(label: Text('IP address')),
          DataColumn(label: Text('MAC address')),
          DataColumn(label: Text('Host name')),
          DataColumn(label: Text('Status')),
          DataColumn(label: Text('Leased at')),
          DataColumn(label: Text('Expires at')),
        ],
        rows: [
          for (final lease in leases)
            DataRow(
              cells: [
                DataCell(SelectableText(lease.ipAddress)),
                DataCell(SelectableText(lease.macAddress)),
                DataCell(
                  SelectableText(lease.hostName.isEmpty ? '—' : lease.hostName),
                ),
                DataCell(Text(lease.status)),
                DataCell(Text(lease.leasedAt)),
                DataCell(Text(lease.expiresAt)),
              ],
            ),
        ],
      ),
    );
  }
}
