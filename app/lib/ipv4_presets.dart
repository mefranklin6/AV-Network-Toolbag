import 'dart:convert';
import 'dart:io';

class Ipv4Preset {
  const Ipv4Preset({
    required this.name,
    required this.address,
    required this.prefixLength,
  });

  final String name;
  final String address;
  final int prefixLength;

  static bool validAddress(String value) {
    final parts = value.trim().split('.');
    return parts.length == 4 &&
        parts.every(
          (part) =>
              RegExp(r'^\d{1,3}$').hasMatch(part) && int.parse(part) <= 255,
        );
  }

  Map<String, Object> toJson() => {
    'name': name,
    'address': address,
    'prefixLength': prefixLength,
  };

  factory Ipv4Preset.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('Each preset must be a JSON object.');
    }
    if (value['name'] is! String ||
        (value['name'] as String).trim().isEmpty ||
        (value['name'] as String).trim().length > 80) {
      throw const FormatException(
        'Preset name must contain 1 to 80 characters.',
      );
    }
    if (value['address'] is! String ||
        !validAddress(value['address'] as String)) {
      throw const FormatException(
        'Preset address must be a valid IPv4 string.',
      );
    }
    if (value['prefixLength'] is! int ||
        (value['prefixLength'] as int) < 0 ||
        (value['prefixLength'] as int) > 32) {
      throw const FormatException(
        'Preset prefixLength must be an integer from 0 to 32.',
      );
    }
    return Ipv4Preset(
      name: (value['name'] as String).trim(),
      address: (value['address'] as String).trim(),
      prefixLength: value['prefixLength'] as int,
    );
  }
}

/// Separate from theme settings so saving either cannot overwrite the other.
class Ipv4PresetStore {
  Ipv4PresetStore({File? file}) : file = file ?? _defaultFile();

  final File file;

  static File _defaultFile() {
    final base = Platform.environment['LOCALAPPDATA'];
    return File(
      '${base == null || base.isEmpty ? Directory.systemTemp.path : base}'
      '${Platform.pathSeparator}AVNetworkToolbag'
      '${Platform.pathSeparator}ipv4-presets.json',
    );
  }

  Future<List<Ipv4Preset>> load() async {
    if (!await file.exists()) return [];
    final contents = await file.readAsString();
    // Windows editors may write a UTF-8 byte-order mark.
    final data = jsonDecode(contents.replaceFirst(RegExp(r'^\uFEFF'), ''));
    if (data is! List) {
      throw const FormatException('Expected a list of IPv4 presets.');
    }
    final presets = <Ipv4Preset>[];
    for (var index = 0; index < data.length; index++) {
      try {
        presets.add(Ipv4Preset.fromJson(data[index]));
      } on FormatException catch (error) {
        throw FormatException('Preset ${index + 1}: ${error.message}');
      }
    }
    final names = presets.map((preset) => preset.name.toLowerCase()).toSet();
    if (names.length != presets.length) {
      throw const FormatException('Duplicate IPv4 preset names.');
    }
    return presets;
  }

  Future<void> save(List<Ipv4Preset> presets) async {
    // An external edit may have happened since the manager was opened. Never
    // replace a malformed file with the older list still visible in the UI.
    await load();
    await file.parent.create(recursive: true);
    // Flush a complete replacement before touching the previous file.
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(
        const JsonEncoder.withIndent('  ')
            .convert(presets.map((preset) => preset.toJson()).toList()),
        flush: true,
      );
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> ensureFileExists() async {
    await file.parent.create(recursive: true);
    if (!await file.exists()) {
      // Exclusive creation prevents overwriting a file created by another app.
      try {
        await file.create(exclusive: true);
      } on FileSystemException {
        if (await file.exists()) return;
        rethrow;
      }
      await file.writeAsString('[]', flush: true);
    }
  }

  Future<void> revealInExplorer() async {
    await ensureFileExists();
    await Process.start('explorer.exe', [
      '/select,',
      file.absolute.path,
    ], mode: ProcessStartMode.detached);
  }
}
