import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'mdns_listener.dart';
import 'models.dart';
import 'windows_network_probe.dart';

class MdnsListenerDialog extends StatefulWidget {
  const MdnsListenerDialog({super.key, required this.adapter});

  final AdapterDetails adapter;

  @override
  State<MdnsListenerDialog> createState() => _MdnsListenerDialogState();
}

class _MdnsListenerDialogState extends State<MdnsListenerDialog> {
  final Map<String, _ObservedDevice> _devices = {};
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  MdnsListenerController? _listener;
  Timer? _refreshTimer;
  Timer? _neighborTimer;
  Timer? _searchDebounce;
  String _status = 'Starting mDNS listener…';
  String _searchQuery = '';
  String? _error;
  bool _starting = true;
  bool _running = false;
  int _sortColumn = 0;
  bool _ascending = true;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_queueSearch);
    unawaited(_start());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _neighborTimer?.cancel();
    _searchDebounce?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    unawaited(_listener?.stop());
    super.dispose();
  }

  Future<void> _start() async {
    if (_starting || _running) {
      if (_listener != null) return;
    }
    setState(() {
      _starting = true;
      _error = null;
      _status = 'Starting mDNS listener…';
    });
    final addresses = <String>[
      ...widget.adapter.ipv4.map((value) => value.address),
      ...widget.adapter.ipv6.map((value) => value.split('%').first),
    ];
    final listener = MdnsListenerController(
      interfaceIndex: widget.adapter.interfaceIndex,
      interfaceAddresses: addresses,
      onPacket: _onPacket,
      onStatus: (status) {
        if (mounted) setState(() => _status = status);
      },
    );
    _listener = listener;
    try {
      await listener.start();
      if (!mounted) return;
      setState(() {
        _running = true;
        _starting = false;
      });
      _neighborTimer?.cancel();
      _neighborTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _enrichMacAddresses(),
      );
    } on Object catch (error) {
      await listener.stop();
      if (!mounted) return;
      setState(() {
        _running = false;
        _starting = false;
        _error = error.toString();
        _status = 'The listener could not be started.';
      });
    }
  }

  Future<void> _stop() async {
    _neighborTimer?.cancel();
    await _listener?.stop();
    if (!mounted) return;
    setState(() {
      _running = false;
      _starting = false;
    });
  }

  void _onPacket(MdnsPacket packet) {
    if (!mounted || !_running && !_starting) return;
    final localMac = widget.adapter.macAddress.toUpperCase();
    if (packet.macAddress.isNotEmpty &&
        packet.macAddress.toUpperCase() == localMac) {
      return;
    }
    final localAddresses = <String>{
      ...widget.adapter.ipv4.map((value) => value.address),
      ...widget.adapter.ipv6.map((value) => value.split('%').first),
    };
    if (localAddresses.contains(packet.sourceAddress)) return;

    final mac = packet.macAddress.toUpperCase();
    _ObservedDevice? device;
    String key;
    if (mac.isNotEmpty) {
      key = mac;
      device = _devices[key];
      if (device == null) {
        final prior = _devices.entries
            .where(
              (entry) =>
                  entry.value.macAddress.isEmpty &&
                  entry.value.addresses.contains(packet.sourceAddress),
            )
            .firstOrNull;
        if (prior != null) {
          device = prior.value;
          _devices.remove(prior.key);
        }
      }
    } else {
      final prior = _devices.entries
          .where(
            (entry) => entry.value.addresses.contains(packet.sourceAddress),
          )
          .firstOrNull;
      device = prior?.value;
      key = prior?.key ?? 'ip:${packet.sourceAddress}';
    }
    device ??= _ObservedDevice(firstSeen: DateTime.now());
    if (mac.isNotEmpty) device.macAddress = mac;
    device
      ..addresses.add(packet.sourceAddress)
      ..addresses.addAll(packet.advertisedAddresses)
      ..hostnames.addAll(packet.hostnames)
      ..lastSeen = DateTime.now();
    device.packetCount++;
    _devices[mac.isNotEmpty ? mac : key] = device;
    _scheduleRefresh();
  }

  void _scheduleRefresh() {
    if (_refreshTimer?.isActive == true) return;
    _refreshTimer = Timer(const Duration(milliseconds: 180), () {
      if (mounted) setState(() {});
    });
  }

  void _enrichMacAddresses() {
    if (!mounted || !_running || widget.adapter.interfaceIndex == 0) return;
    try {
      final neighbors = queryWindowsIpv4Neighbors(
        widget.adapter.interfaceIndex,
      );
      var changed = false;
      for (final entry in _devices.entries.toList()) {
        final device = entry.value;
        if (device.macAddress.isNotEmpty) continue;
        String? mac;
        for (final address in device.addresses) {
          mac = neighbors[address];
          if (mac != null) break;
        }
        if (mac == null || mac.isEmpty) continue;
        _devices.remove(entry.key);
        final existing = _devices[mac];
        if (existing == null) {
          device.macAddress = mac;
          _devices[mac] = device;
        } else {
          existing
            ..addresses.addAll(device.addresses)
            ..hostnames.addAll(device.hostnames)
            ..packetCount += device.packetCount;
          if (device.firstSeen.isBefore(existing.firstSeen)) {
            existing.firstSeen = device.firstSeen;
          }
          if (device.lastSeen.isAfter(existing.lastSeen)) {
            existing.lastSeen = device.lastSeen;
          }
        }
        changed = true;
      }
      if (changed) setState(() {});
    } on Object {
      // Neighbor enrichment is optional when layer-2 capture is unavailable.
    }
  }

  void _queueSearch() {
    _searchDebounce?.cancel();
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) {
      if (_searchQuery.isEmpty) return;
      setState(() => _searchQuery = '');
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 180), () {
      if (mounted) setState(() => _searchQuery = query);
    });
  }

  List<_ObservedDevice> get _visibleDevices {
    final values = _devices.values.where((device) {
      if (_searchQuery.isEmpty) return true;
      return device.macAddress.toLowerCase().contains(_searchQuery) ||
          device.addresses.any(
            (address) => address.toLowerCase().contains(_searchQuery),
          ) ||
          device.hostnames.any(
            (hostname) => hostname.toLowerCase().contains(_searchQuery),
          );
    }).toList();
    int compare(_ObservedDevice left, _ObservedDevice right) {
      return switch (_sortColumn) {
        1 => _firstHostname(left).compareTo(_firstHostname(right)),
        2 => left.macAddress.compareTo(right.macAddress),
        _ => _compareAddresses(_firstAddress(left), _firstAddress(right)),
      };
    }

    values.sort(
      (left, right) => _ascending ? compare(left, right) : compare(right, left),
    );
    return values;
  }

  String _firstAddress(_ObservedDevice device) =>
      device.sortedAddresses.firstOrNull ?? '';

  String _firstHostname(_ObservedDevice device) =>
      (device.sortedHostnames.firstOrNull ?? '').toLowerCase();

  int _compareAddresses(String left, String right) {
    final leftAddress = InternetAddress.tryParse(left);
    final rightAddress = InternetAddress.tryParse(right);
    if (leftAddress == null || rightAddress == null) {
      return left.toLowerCase().compareTo(right.toLowerCase());
    }
    if (leftAddress.type != rightAddress.type) {
      return leftAddress.type == InternetAddressType.IPv4 ? -1 : 1;
    }
    final leftBytes = leftAddress.rawAddress;
    final rightBytes = rightAddress.rawAddress;
    for (var index = 0; index < leftBytes.length; index++) {
      final result = leftBytes[index].compareTo(rightBytes[index]);
      if (result != 0) return result;
    }
    return 0;
  }

  void _sort(int column) => setState(() {
    if (_sortColumn == column) {
      _ascending = !_ascending;
    } else {
      _sortColumn = column;
      _ascending = true;
    }
  });

  Future<void> _copy() async {
    final devices = _visibleDevices;
    final output = StringBuffer('IP Addresses\tHostnames\tMAC Address\r\n');
    for (final device in devices) {
      output.writeln(
        '${device.sortedAddresses.join(', ')}\t'
        '${device.sortedHostnames.join(', ')}\t'
        '${device.macAddress.isEmpty ? '(unavailable)' : device.macAddress}',
      );
    }
    await Clipboard.setData(ClipboardData(text: output.toString()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Copied ${devices.length} devices.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact = Theme.of(context).visualDensity.vertical < 0;
    final devices = _visibleDevices;
    final media = MediaQuery.sizeOf(context);
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      label: 'mDNS Listener',
      explicitChildNodes: true,
      child: Dialog(
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: (media.width - 48).clamp(560.0, 1080.0).toDouble(),
          height: (media.height - 48).clamp(420.0, 780.0).toDouble(),
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
                    Icon(Icons.wifi_tethering, color: scheme.primary, size: 34),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'mDNS Listener',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${widget.adapter.alias} · ${_devices.length} unique devices',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close mDNS listener',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  compact ? 14 : 24,
                  compact ? 10 : 18,
                  compact ? 14 : 24,
                  compact ? 8 : 14,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _error ?? _status,
                        style: TextStyle(
                          color: _error == null ? null : scheme.error,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Passively records source IPs that send IPv4 or IPv6 mDNS traffic. '
                      'Hostnames and advertised addresses appear when present; MAC is optional.',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  compact ? 14 : 24,
                  0,
                  compact ? 14 : 24,
                  compact ? 8 : 14,
                ),
                child: TextField(
                  controller: _searchController,
                  enabled: _devices.isNotEmpty,
                  decoration: InputDecoration(
                    labelText: 'Filter devices',
                    hintText: 'Hostname, MAC address, or IP address',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchController.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear filter',
                            onPressed: _searchController.clear,
                            icon: const Icon(Icons.clear),
                          ),
                  ),
                ),
              ),
              Expanded(
                child: _devices.isEmpty
                    ? Center(
                        child: Text(
                          _starting
                              ? 'Opening the selected interface…'
                              : _running
                              ? 'Listening for mDNS traffic…'
                              : 'No devices captured.',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      )
                    : Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: compact ? 14 : 24,
                        ),
                        child: Column(
                          children: [
                            _buildTableHeader(scheme),
                            const Divider(height: 1),
                            Expanded(
                              child: devices.isEmpty
                                  ? Center(
                                      child: Text(
                                        'No devices match the filter.',
                                        style: TextStyle(
                                          color: scheme.onSurfaceVariant,
                                        ),
                                      ),
                                    )
                                  : Scrollbar(
                                      controller: _scrollController,
                                      child: ListView.builder(
                                        controller: _scrollController,
                                        itemExtent: compact ? 42 : 54,
                                        itemCount: devices.length,
                                        itemBuilder: (context, index) {
                                          final device = devices[index];
                                          final mac = device.macAddress.isEmpty
                                              ? '(unavailable)'
                                              : device.macAddress;
                                          final ips = device.sortedAddresses
                                              .join(', ');
                                          final names =
                                              device.sortedHostnames.isEmpty
                                              ? '(not advertised)'
                                              : device.sortedHostnames.join(
                                                  ', ',
                                                );
                                          return Semantics(
                                            label:
                                                'MAC address $mac, IP addresses $ips, hostnames $names',
                                            child: ExcludeSemantics(
                                              child: ColoredBox(
                                                color: index.isEven
                                                    ? Colors.transparent
                                                    : scheme
                                                          .surfaceContainerLowest,
                                                child: Row(
                                                  children: [
                                                    Expanded(
                                                      flex: 2,
                                                      child: Tooltip(
                                                        message: ips,
                                                        child: Padding(
                                                          padding:
                                                              const EdgeInsets.symmetric(
                                                                horizontal: 12,
                                                              ),
                                                          child: Text(
                                                            ips,
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                    Expanded(
                                                      flex: 3,
                                                      child: Tooltip(
                                                        message: names,
                                                        child: Padding(
                                                          padding:
                                                              const EdgeInsets.symmetric(
                                                                horizontal: 12,
                                                              ),
                                                          child: Text(
                                                            names,
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                    SizedBox(
                                                      width: 205,
                                                      child: Padding(
                                                        padding:
                                                            const EdgeInsets.symmetric(
                                                              horizontal: 12,
                                                            ),
                                                        child: SelectableText(
                                                          mac,
                                                          maxLines: 1,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                            ),
                          ],
                        ),
                      ),
              ),
              Padding(
                padding: EdgeInsets.all(compact ? 12 : 20),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    OutlinedButton.icon(
                      onPressed: devices.isEmpty ? null : _copy,
                      icon: const Icon(Icons.copy_all_outlined),
                      label: const Text('Copy report'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _devices.isEmpty
                          ? null
                          : () => setState(_devices.clear),
                      icon: const Icon(Icons.delete_sweep_outlined),
                      label: const Text('Clear'),
                    ),
                    if (_running)
                      FilledButton.icon(
                        onPressed: _stop,
                        icon: const Icon(Icons.stop_circle_outlined),
                        label: const Text('Stop listening'),
                      )
                    else
                      FilledButton.icon(
                        onPressed: _starting ? null : _start,
                        icon: const Icon(Icons.play_circle_outline),
                        label: const Text('Start listening'),
                      ),
                    OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTableHeader(ColorScheme scheme) {
    final compact = Theme.of(context).visualDensity.vertical < 0;
    return Container(
      height: compact ? 38 : 44,
      color: scheme.surfaceContainerLow,
      child: Row(
        children: [
          Expanded(flex: 2, child: _sortButton('IP addresses', 0)),
          Expanded(flex: 3, child: _sortButton('Hostnames', 1)),
          SizedBox(width: 205, child: _sortButton('MAC address (if known)', 2)),
        ],
      ),
    );
  }

  Widget _sortButton(String label, int column) {
    final selected = _sortColumn == column;
    return Semantics(
      button: true,
      label:
          '$label, ${selected ? (_ascending ? 'sorted ascending' : 'sorted descending') : 'not sorted'}',
      child: TextButton(
        style: TextButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        onPressed: () => _sort(column),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (selected) ...[
              const SizedBox(width: 4),
              Icon(
                _ascending ? Icons.arrow_upward : Icons.arrow_downward,
                size: 16,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ObservedDevice {
  _ObservedDevice({required this.firstSeen}) : lastSeen = firstSeen;

  String macAddress = '';
  final Set<String> addresses = {};
  final Set<String> hostnames = {};
  DateTime firstSeen;
  DateTime lastSeen;
  int packetCount = 0;

  List<String> get sortedAddresses => addresses.toList()..sort();
  List<String> get sortedHostnames => hostnames.toList()..sort();
}
