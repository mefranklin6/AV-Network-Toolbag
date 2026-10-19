import 'dart:convert';
import 'dart:io';

import 'package:av_network_toolbag/ipv4_presets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late File file;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('avnt-presets-');
    file = File('${directory.path}/settings/ipv4-presets.json');
  });
  tearDown(() async => directory.delete(recursive: true));

  test('presets survive new store instances and deletion', () async {
    final store = Ipv4PresetStore(file: file);
    expect(await store.load(), isEmpty);
    await store.save([
      const Ipv4Preset(name: 'Stage', address: '10.42.0.10', prefixLength: 16),
      const Ipv4Preset(name: 'Desk', address: '192.168.1.10', prefixLength: 24),
    ]);
    final restored = await Ipv4PresetStore(file: file).load();
    expect(restored.first.name, 'Stage');
    expect(restored.first.address, '10.42.0.10');
    expect(restored.first.prefixLength, 16);
    await store.save(restored.skip(1).toList());
    expect((await store.load()).single.name, 'Desk');
    await store.save([]);
    expect(await store.load(), isEmpty);
    expect(await File('${file.path}.tmp').exists(), isFalse);
  });

  test('invalid files report errors without modifying saved data', () async {
    await file.parent.create(recursive: true);
    for (final content in [
      '{broken',
      '{}',
      'null',
      '[null]',
      '["preset"]',
      '[{}]',
      '[{"name":"", "address":"10.1.1.1", "prefixLength":24}]',
      '[{"name":"Desk", "address":123, "prefixLength":24}]',
      '[{"name":"Desk", "address":"10.1.1.1", "prefixLength":"24"}]',
      '[{"name":"Desk", "address":"10.1.1.1", "prefixLength":24.5}]',
      '[{"name":"Desk", "address":"10.1.1.1", "prefixLength":-1}]',
      jsonEncode([
        {'name': 'x' * 81, 'address': '10.1.1.1', 'prefixLength': 24},
      ]),
      jsonEncode([
        {'name': 'Bad', 'address': '999.1.1.1', 'prefixLength': 24},
      ]),
      jsonEncode([
        {'name': 'Bad', 'address': '10.1.1.1', 'prefixLength': 33},
      ]),
      jsonEncode([
        {'name': 'Desk', 'address': '10.1.1.1', 'prefixLength': 24},
        {'name': 'desk', 'address': '10.1.1.2', 'prefixLength': 24},
      ]),
    ]) {
      await file.writeAsString(content);
      await expectLater(
        Ipv4PresetStore(file: file).load(),
        throwsFormatException,
      );
      expect(await file.readAsString(), content);
    }
  });

  test('external malformed edits block saves until repaired', () async {
    final store = Ipv4PresetStore(file: file);
    const preset = Ipv4Preset(
      name: 'Stage',
      address: '10.1.1.1',
      prefixLength: 24,
    );
    await store.save([preset]);
    await file.writeAsString('[broken');
    await expectLater(store.save([]), throwsFormatException);
    expect(await file.readAsString(), '[broken');
    await file.writeAsString('[]');
    await store.save([preset]);
    expect((await store.load()).single.name, 'Stage');
  });

  test(
    'Explorer preparation creates missing JSON and preserves existing files',
    () async {
      final store = Ipv4PresetStore(file: file);
      await store.ensureFileExists();
      expect(await file.readAsString(), '[]');
      await file.writeAsString('{broken');
      await store.ensureFileExists();
      expect(await file.readAsString(), '{broken');
    },
  );

  test('Windows editor UTF-8 BOM is accepted', () async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '\uFEFF[{"name":"Stage","address":"10.1.1.1","prefixLength":24}]',
    );
    expect((await Ipv4PresetStore(file: file).load()).single.name, 'Stage');
  });
}
