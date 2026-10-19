import 'package:flutter/material.dart';

import 'ipv4_presets.dart';

class Ipv4PresetsDialog extends StatefulWidget {
  const Ipv4PresetsDialog({
    super.key,
    required this.store,
    required this.onChanged,
    required this.initialAddress,
    required this.initialPrefix,
  });

  final Ipv4PresetStore store;
  final ValueChanged<List<Ipv4Preset>> onChanged;
  final String initialAddress;
  final int initialPrefix;

  @override
  State<Ipv4PresetsDialog> createState() => _Ipv4PresetsDialogState();
}

class _Ipv4PresetsDialogState extends State<Ipv4PresetsDialog> {
  List<Ipv4Preset> _presets = [];
  bool _loading = true;
  bool _saving = false;
  bool _loaded = false;
  bool _openingJson = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final presets = await widget.store.load();
      if (!mounted) return;
      setState(() {
        _presets = presets;
        _loaded = true;
        _error = null;
      });
      widget.onChanged(presets);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _loaded = false;
          _error =
              'Could not load presets: $error. Fix the JSON file and reload.';
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openJson() async {
    setState(() => _openingJson = true);
    try {
      await widget.store.revealInExplorer();
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not open File Explorer: $error');
      }
    } finally {
      if (mounted) setState(() => _openingJson = false);
    }
  }

  Future<void> _save(List<Ipv4Preset> presets) async {
    setState(() => _saving = true);
    try {
      await widget.store.save(presets);
      if (!mounted) return;
      setState(() {
        _presets = presets;
        _error = null;
      });
      widget.onChanged(presets);
    } on Object catch (error) {
      if (mounted) setState(() => _error = 'Could not save presets: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _edit([Ipv4Preset? existing]) async {
    final preset = await showDialog<Ipv4Preset>(
      context: context,
      builder: (_) => _PresetEditor(
        existing: existing,
        presets: _presets,
        initialAddress: widget.initialAddress,
        initialPrefix: widget.initialPrefix,
      ),
    );
    if (preset == null || !mounted) return;
    await _save([
      for (final item in _presets) item == existing ? preset : item,
      if (existing == null) preset,
    ]);
  }

  Future<void> _delete(Ipv4Preset preset) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete preset?'),
        content: Text(
          'Delete "${preset.name}" (${preset.address}/${preset.prefixLength})?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _save(_presets.where((item) => item != preset).toList());
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: const Text('Manage presets'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_loading || _saving) const LinearProgressIndicator(),
              if (_error != null) ...[
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
              if (_loaded && _presets.isEmpty)
                const Text(
                  'No presets yet. Add an IPv4 address and CIDR prefix to get started.',
                ),
              for (final preset in _presets)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        preset.name,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final disabled = _saving || _loading || !_loaded;
                          final compact = constraints.maxWidth < 440;
                          return Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${preset.address}/${preset.prefixLength}',
                                ),
                              ),
                              if (compact) ...[
                                IconButton(
                                  onPressed: disabled
                                      ? null
                                      : () => _edit(preset),
                                  tooltip: 'Rename',
                                  icon: const Icon(Icons.edit_outlined),
                                ),
                                IconButton(
                                  onPressed: disabled
                                      ? null
                                      : () => _delete(preset),
                                  tooltip: 'Delete',
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ] else ...[
                                TextButton.icon(
                                  onPressed: disabled
                                      ? null
                                      : () => _edit(preset),
                                  icon: const Icon(Icons.edit_outlined),
                                  label: const Text('Rename'),
                                ),
                                TextButton.icon(
                                  onPressed: disabled
                                      ? null
                                      : () => _delete(preset),
                                  icon: const Icon(Icons.delete_outline),
                                  label: const Text('Delete'),
                                ),
                              ],
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        OutlinedButton.icon(
          onPressed: _saving || _loading || _openingJson ? null : _openJson,
          icon: const Icon(Icons.folder_open_outlined),
          label: const Text('Open JSON'),
        ),
        TextButton.icon(
          onPressed: _saving || _loading ? null : _load,
          icon: const Icon(Icons.refresh),
          label: const Text('Reload'),
        ),
        OutlinedButton.icon(
          onPressed: _loaded && !_saving && !_loading ? () => _edit() : null,
          icon: const Icon(Icons.add),
          label: const Text('Add preset'),
        ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}

class _PresetEditor extends StatefulWidget {
  const _PresetEditor({
    required this.existing,
    required this.presets,
    required this.initialAddress,
    required this.initialPrefix,
  });

  final Ipv4Preset? existing;
  final List<Ipv4Preset> presets;
  final String initialAddress;
  final int initialPrefix;

  @override
  State<_PresetEditor> createState() => _PresetEditorState();
}

class _PresetEditorState extends State<_PresetEditor> {
  final formKey = GlobalKey<FormState>();
  late String name = widget.existing?.name ?? '';
  late String address = widget.existing?.address ?? widget.initialAddress;
  late int prefix = widget.existing?.prefixLength ?? widget.initialPrefix;

  @override
  Widget build(BuildContext context) {
    void submit() {
      if (!formKey.currentState!.validate()) return;
      formKey.currentState!.save();
      Navigator.pop(
        context,
        Ipv4Preset(name: name, address: address, prefixLength: prefix),
      );
    }

    return AlertDialog(
      title: Text(
        widget.existing == null ? 'Add IPv4 preset' : 'Rename preset',
      ),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  initialValue: name,
                  autofocus: true,
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: 'Preset name'),
                  validator: (value) {
                    final name = value?.trim() ?? '';
                    if (name.isEmpty) return 'Enter a preset name';
                    if (widget.presets.any(
                      (p) =>
                          p != widget.existing &&
                          p.name.toLowerCase() == name.toLowerCase(),
                    )) {
                      return 'A preset with this name already exists';
                    }
                    return null;
                  },
                  onSaved: (value) => name = value!.trim(),
                  onFieldSubmitted: (_) => submit(),
                ),
                if (widget.existing == null) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    initialValue: address,
                    decoration: const InputDecoration(labelText: 'IP address'),
                    validator: (value) => Ipv4Preset.validAddress(value ?? '')
                        ? null
                        : 'Enter a valid IPv4 address',
                    onSaved: (value) => address = value!.trim(),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: prefix,
                    decoration: const InputDecoration(labelText: 'CIDR prefix'),
                    items: [
                      for (var value = 0; value <= 32; value++)
                        DropdownMenuItem(value: value, child: Text('/$value')),
                    ],
                    onChanged: (value) => prefix = value!,
                  ),
                ] else
                  Text('$address/$prefix'),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: submit, child: const Text('Save')),
      ],
    );
  }
}
