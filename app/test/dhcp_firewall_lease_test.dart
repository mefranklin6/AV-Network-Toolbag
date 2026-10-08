import 'dart:async';
import 'dart:io';

import 'package:av_network_toolbag/dhcp_firewall_lease.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('avnt-firewall-test-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  const name = 'AVNetworkToolbag-Dart-123-456';

  test(
    'recovery removes abandoned rules and ignores unrelated files',
    () async {
      await File('${directory.path}/$name').create();
      await File('${directory.path}/unrelated').create();
      final removed = <String>[];
      await DhcpFirewallLease.recover(directory, (rule) async {
        removed.add(rule);
      });
      expect(removed, [name]);
      expect(await File('${directory.path}/$name').exists(), isFalse);
      expect(await File('${directory.path}/unrelated').exists(), isTrue);
    },
  );
  test('live instance retains rule until awaited release', () async {
    final lease = await DhcpFirewallLease.acquire(directory, name);
    final removed = <String>[];
    try {
      await DhcpFirewallLease.recover(directory, (rule) async {
        removed.add(rule);
      });
      expect(removed, isEmpty);
    } finally {
      await lease.release((rule) async {
        removed.add(rule);
      });
    }
    expect(removed, [name]);
    expect(await lease.file.exists(), isFalse);
  }, skip: !Platform.isWindows);
  test('failed cleanup keeps the journal for retry', () async {
    await File('${directory.path}/$name').create();
    await DhcpFirewallLease.recover(directory, (_) async {
      throw StateError('denied');
    });
    expect(await File('${directory.path}/$name').exists(), isTrue);
  });

  test(
    'concurrent release shares cleanup and failed release can retry',
    () async {
      final lease = await DhcpFirewallLease.acquire(directory, name);
      await expectLater(
        lease.release((_) async {
          throw StateError('denied');
        }),
        throwsStateError,
      );
      expect(await lease.file.exists(), isTrue);
      final gate = Completer<void>();
      var calls = 0;
      Future<void> remove(String _) async {
        calls++;
        await gate.future;
      }

      final first = lease.release(remove);
      final second = lease.release(remove);
      gate.complete();
      await Future.wait([first, second]);
      expect(calls, 1);
      expect(await lease.file.exists(), isFalse);
    },
  );
}
