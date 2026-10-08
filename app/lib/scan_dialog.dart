import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'backend_service.dart';
import 'models.dart';

class SubnetScanDialog extends StatefulWidget {
  const SubnetScanDialog({
    super.key,
    required this.backend,
    required this.plan,
  });

  final NetworkBackend backend;
  final ScanPlan plan;

  @override
  State<SubnetScanDialog> createState() => _SubnetScanDialogState();
}

class _SubnetScanDialogState extends State<SubnetScanDialog> {
  final _searchController = TextEditingController();
  final _resultsScrollController = ScrollController();
  Timer? _timer;
  Timer? _searchDebounce;
  ScanStatus? _status;
  List<ScanResult> _sortedResults = const [];
  List<ScanResult> _visibleResults = const [];
  String _searchQuery = '';
  bool _polling = false;
  bool _cancelling = false;
  int _sortColumn = 0;
  bool _ascending = true;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_queueSearch);
    _poll();
    _timer = Timer.periodic(const Duration(milliseconds: 350), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _searchDebounce?.cancel();
    _searchController.dispose();
    _resultsScrollController.dispose();
    if (_status?.complete != true) unawaited(widget.backend.cancelScan());
    super.dispose();
  }

  Future<void> _poll() async {
    if (_polling || _status?.complete == true) return;
    _polling = true;
    try {
      final status = await widget.backend.getScanStatus();
      if (!mounted) return;
      setState(() {
        _status = status;
        if (status.complete) {
          _sortedResults = _sortResults(status.results);
          _visibleResults = _filterResults(_sortedResults);
        }
      });
      if (status.complete) _timer?.cancel();
    } on Object catch (error) {
      if (!mounted) return;
      _timer?.cancel();
      setState(
        () => _status = ScanStatus(
          progress: 0,
          status: 'The scan could not be completed.',
          activeCount: 0,
          complete: true,
          cancelled: false,
          error: error.toString(),
          results: const [],
        ),
      );
    } finally {
      _polling = false;
    }
  }

  void _queueSearch() {
    _searchDebounce?.cancel();
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) {
      if (_searchQuery.isEmpty) return;
      setState(() {
        _searchQuery = '';
        _visibleResults = _sortedResults;
      });
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 180), () {
      if (!mounted) return;
      setState(() {
        _searchQuery = query;
        _visibleResults = _filterResults(_sortedResults);
      });
    });
  }

  List<ScanResult> _filterResults(List<ScanResult> source) {
    if (_searchQuery.isEmpty) return source;
    return source
        .where(
          (result) =>
              result.hostname.toLowerCase().contains(_searchQuery) ||
              result.macAddress.toLowerCase().contains(_searchQuery) ||
              result.ipAddress.contains(_searchQuery),
        )
        .toList(growable: false);
  }

  List<ScanResult> _sortResults(List<ScanResult> source) {
    final values = List<ScanResult>.of(source);
    int compare(ScanResult left, ScanResult right) => switch (_sortColumn) {
      1 => left.hostname.toLowerCase().compareTo(right.hostname.toLowerCase()),
      2 => left.macAddress.compareTo(right.macAddress),
      _ => _ipValue(left.ipAddress).compareTo(_ipValue(right.ipAddress)),
    };
    values.sort(
      (left, right) => _ascending ? compare(left, right) : compare(right, left),
    );
    return values;
  }

  int _ipValue(String address) {
    final parts = address.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((part) => part == null)) return 0;
    return ((parts[0]! << 24) |
            (parts[1]! << 16) |
            (parts[2]! << 8) |
            parts[3]!) &
        0xFFFFFFFF;
  }

  void _sort(int column, bool ascending) => setState(() {
    _sortColumn = column;
    _ascending = ascending;
    _sortedResults = _sortResults(_status?.results ?? const []);
    _visibleResults = _filterResults(_sortedResults);
  });

  Future<void> _cancel() async {
    setState(() => _cancelling = true);
    try {
      await widget.backend.cancelScan();
    } on Object catch (error) {
      if (mounted) _showMessage(error.toString());
    }
  }

  Future<void> _copy() async {
    final rows = _status?.results ?? const <ScanResult>[];
    final report = StringBuffer('IP Address\tHostname\tMAC Address\r\n');
    for (final row in rows) {
      report.writeln('${row.ipAddress}\t${row.hostname}\t${row.macAddress}');
    }
    await Clipboard.setData(ClipboardData(text: report.toString()));
    if (mounted) _showMessage('Copied ${rows.length} scan results.');
  }

  Future<void> _export() async {
    try {
      final path = await widget.backend.exportScanCsv();
      if (mounted && path != null) _showMessage('Saved scan report to $path');
    } on Object catch (error) {
      if (mounted) _showMessage(error.toString());
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final complete = status?.complete == true;
    final results = _visibleResults;
    final scheme = Theme.of(context).colorScheme;
    final compact = Theme.of(context).visualDensity.vertical < 0;
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      label: 'Subnet scan',
      explicitChildNodes: true,
      child: Dialog(
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: 1000,
            maxHeight: 760,
            minWidth: 560,
            minHeight: 420,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                color: scheme.surfaceContainerLow,
                padding: EdgeInsets.fromLTRB(
                  compact ? 14 : 24,
                  compact ? 12 : 22,
                  compact ? 10 : 16,
                  compact ? 10 : 18,
                ),
                child: Row(
                  children: [
                    Icon(Icons.radar_rounded, color: scheme.primary, size: 32),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${complete ? 'Subnet scan' : 'Scanning'} ${widget.plan.networkAddress}/${widget.plan.prefixLength}',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${widget.plan.hostCount} addresses via ${widget.plan.interfaceAlias}',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    if (complete)
                      IconButton(
                        tooltip: 'Close subnet scan',
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
                  compact ? 8 : 12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      liveRegion: true,
                      label: status?.status ?? 'Starting scan',
                      child: Text(
                        status?.error.isNotEmpty == true
                            ? status!.error
                            : status?.status ?? 'Starting scan…',
                        style: TextStyle(
                          color: status?.error.isNotEmpty == true
                              ? scheme.error
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (complete)
                      Container(
                        height: 4,
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      )
                    else
                      LinearProgressIndicator(
                        value: status == null ? null : status.progress / 100,
                        semanticsLabel: 'Subnet scan progress',
                        semanticsValue: status == null
                            ? 'Starting'
                            : '${status.progress} percent',
                      ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _searchController,
                      enabled:
                          complete && (status?.results.isNotEmpty ?? false),
                      decoration: InputDecoration(
                        labelText: 'Filter results',
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
                  ],
                ),
              ),
              Expanded(
                child: results.isEmpty
                    ? Center(
                        child: Text(
                          complete
                              ? (_searchController.text.isEmpty
                                    ? 'No hosts replied to ping.'
                                    : 'No matching hosts.')
                              : 'Active hosts will appear when the scan completes.',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      )
                    : Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: compact ? 14 : 24,
                        ),
                        child: Column(
                          children: [
                            _buildResultHeader(context),
                            const Divider(height: 1),
                            Expanded(
                              child: Scrollbar(
                                controller: _resultsScrollController,
                                child: ListView.builder(
                                  controller: _resultsScrollController,
                                  itemExtent: compact ? 40 : 48,
                                  itemCount: results.length,
                                  itemBuilder: (context, index) =>
                                      _buildResultRow(
                                        context,
                                        results[index],
                                        index,
                                      ),
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
                      onPressed:
                          complete && (status?.results.isNotEmpty ?? false)
                          ? _copy
                          : null,
                      icon: const Icon(Icons.copy_all_outlined),
                      label: const Text('Copy report'),
                    ),
                    OutlinedButton.icon(
                      onPressed:
                          complete && (status?.results.isNotEmpty ?? false)
                          ? _export
                          : null,
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('Export CSV'),
                    ),
                    FilledButton.icon(
                      onPressed: complete
                          ? () => Navigator.pop(context)
                          : (_cancelling ? null : _cancel),
                      icon: Icon(
                        complete
                            ? Icons.arrow_back
                            : Icons.stop_circle_outlined,
                      ),
                      label: Text(
                        complete
                            ? 'Back'
                            : (_cancelling ? 'Cancelling…' : 'Cancel scan'),
                      ),
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

  Widget _buildResultHeader(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact = Theme.of(context).visualDensity.vertical < 0;
    return Container(
      height: compact ? 40 : 48,
      color: scheme.surfaceContainerLow,
      child: Row(
        children: [
          SizedBox(width: 176, child: _sortButton('IP address', 0)),
          Expanded(child: _sortButton('Hostname', 1)),
          SizedBox(width: 210, child: _sortButton('MAC address', 2)),
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
        onPressed: () => _sort(column, selected ? !_ascending : true),
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

  Widget _buildResultRow(BuildContext context, ScanResult result, int index) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label:
          'IP address ${result.ipAddress}, hostname '
          '${result.hostname.isEmpty ? 'not found' : result.hostname}, '
          'MAC address ${result.macAddress.isEmpty ? 'not found' : result.macAddress}',
      child: ExcludeSemantics(
        child: ColoredBox(
          color: index.isEven
              ? Colors.transparent
              : scheme.surfaceContainerLowest,
          child: Row(
            children: [
              SizedBox(
                width: 176,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(result.ipAddress, maxLines: 1),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Tooltip(
                    message: result.hostname,
                    child: Text(
                      result.hostname,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 210,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(result.macAddress, maxLines: 1),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
