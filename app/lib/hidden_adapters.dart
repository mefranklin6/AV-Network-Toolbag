import 'dart:convert';
import 'dart:io';

/// Adapter aliases the user chose to hide from the adapter list. Windows
/// aliases are case-insensitive, so they are stored and compared lowercased.
class HiddenAdapterStore {
  HiddenAdapterStore({File? file}) : file = file ?? _defaultFile();

  final File file;

  static File _defaultFile() {
    final base = Platform.environment['LOCALAPPDATA'];
    return File(
      '${base == null || base.isEmpty ? Directory.systemTemp.path : base}'
      '${Platform.pathSeparator}AVNetworkToolbag'
      '${Platform.pathSeparator}hidden-adapters.json',
    );
  }

  static String normalize(String alias) => alias.trim().toLowerCase();

  Future<Set<String>> load() async {
    if (!await file.exists()) return {};
    final contents = await file.readAsString();
    // Windows editors may write a UTF-8 byte-order mark.
    final data = jsonDecode(contents.replaceFirst(RegExp(r'^﻿'), ''));
    if (data is! List || data.any((alias) => alias is! String)) {
      throw const FormatException('Expected a list of adapter names.');
    }
    return data
        .cast<String>()
        .map(normalize)
        .where((alias) => alias.isNotEmpty)
        .toSet();
  }

  Future<void> save(Set<String> aliases) async {
    await file.parent.create(recursive: true);
    // Flush a complete replacement before touching the previous file.
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(
        const JsonEncoder.withIndent('  ').convert(aliases.toList()..sort()),
        flush: true,
      );
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
