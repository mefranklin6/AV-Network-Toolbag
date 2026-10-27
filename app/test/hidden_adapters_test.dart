import 'dart:io';

import 'package:av_network_toolbag/hidden_adapters.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late File file;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('avnt-hidden-');
    file = File('${directory.path}/settings/hidden-adapters.json');
  });
  tearDown(() async => directory.delete(recursive: true));

  test('hidden adapters survive new store instances', () async {
    final store = HiddenAdapterStore(file: file);
    expect(await store.load(), isEmpty);
    await store.save({'ethernet', 'wi-fi'});
    expect(await HiddenAdapterStore(file: file).load(), {'ethernet', 'wi-fi'});
    await store.save({});
    expect(await store.load(), isEmpty);
  });

  test('aliases are normalized and a BOM is accepted', () async {
    await file.parent.create(recursive: true);
    await file.writeAsString('﻿[" Ethernet 2 ", "", "WI-FI"]');
    expect(await HiddenAdapterStore(file: file).load(), {
      'ethernet 2',
      'wi-fi',
    });
  });

  test('malformed files are rejected', () async {
    await file.parent.create(recursive: true);
    await file.writeAsString('{"alias": "Ethernet"}');
    await expectLater(
      HiddenAdapterStore(file: file).load(),
      throwsFormatException,
    );
    await file.writeAsString('[1]');
    await expectLater(
      HiddenAdapterStore(file: file).load(),
      throwsFormatException,
    );
  });
}
