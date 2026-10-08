import 'dart:io';

/// A locked journal lets another instance distinguish active rules from rules
/// left by a crashed process. Record ownership before creating the OS rule.
class DhcpFirewallLease {
  DhcpFirewallLease._(this.file, this.ruleName, this._lock);

  final File file;
  final String ruleName;
  RandomAccessFile? _lock;
  Future<void>? _releaseFuture;

  static final _rulePattern = RegExp(r'^AVNetworkToolbag-Dart-\d+-\d+$');

  static Future<DhcpFirewallLease> acquire(
    Directory directory,
    String ruleName,
  ) async {
    if (!_rulePattern.hasMatch(ruleName)) {
      throw ArgumentError.value(ruleName, 'ruleName');
    }
    await directory.create(recursive: true);
    final file = File('${directory.path}${Platform.pathSeparator}$ruleName');
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
      return DhcpFirewallLease._(file, ruleName, handle);
    } on Object {
      await handle.close();
      rethrow;
    }
  }

  static Future<void> recover(
    Directory directory,
    Future<void> Function(String ruleName) removeRule,
  ) async {
    if (!await directory.exists()) return;
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      if (!_rulePattern.hasMatch(name)) continue;
      RandomAccessFile? handle;
      var removed = false;
      try {
        handle = await entry.open(mode: FileMode.append);
        // Nonblocking: a live owner (or another recovery) retains its rule.
        await handle.lock(FileLock.exclusive);
        await removeRule(name);
        removed = true;
      } on FileSystemException {
        // Locked by a live process, or temporarily inaccessible. Retry later.
      } on Object {
        // Retain the journal when Windows cannot remove the rule.
      } finally {
        await handle?.close();
      }
      if (removed) {
        try {
          await entry.delete();
        } on FileSystemException {
          // A concurrent recovery may already have removed the journal.
        }
      }
    }
  }

  Future<void> release(Future<void> Function(String) removeRule) =>
      _releaseFuture ??= _release(removeRule).catchError((Object error) {
        _releaseFuture = null;
        throw error;
      });

  Future<void> _release(Future<void> Function(String) removeRule) async {
    if (_lock == null) return;
    // On failure retain both ownership and the journal so close can be retried.
    await removeRule(ruleName);
    await _lock!.close();
    _lock = null;
    try {
      await file.delete();
    } on FileSystemException {
      // The rule is gone; a future recovery can discard a leftover journal.
    }
  }
}
