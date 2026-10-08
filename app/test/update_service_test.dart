import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:av_network_toolbag/update_service.dart';

const zipName = 'AV-Network-Toolbag-v1.0.1-windows-x64.zip';
const setupName = 'AV-Network-Toolbag-v1.0.1-windows-x64-Setup.exe';

Map<String, dynamic> metadata(List<String> names) => {
  'tag_name': 'v1.0.1',
  'html_url': 'https://example.invalid/releases/v1.0.1',
  'assets': [
    for (final name in names)
      {'name': name, 'browser_download_url': 'https://example.invalid/$name'},
  ],
};

void main() {
  test('installed and portable copies select different release assets', () {
    final value = metadata([zipName, setupName, 'SHA256SUMS.txt']);
    final installed = UpdateService.parseUpdateRelease(value, installed: true);
    final portable = UpdateService.parseUpdateRelease(value, installed: false);
    expect(installed.archiveName, setupName);
    expect(installed.installer, isTrue);
    expect(portable.archiveName, zipName);
    expect(portable.installer, isFalse);
    expect(installed.isNewerThan('1.0.0'), isTrue);
  });

  test('installed copies never fall back to a portable ZIP', () {
    expect(
      () => UpdateService.parseUpdateRelease(
        metadata([zipName, 'SHA256SUMS.txt']),
        installed: true,
      ),
      throwsA(isA<UpdateException>()),
    );
    expect(
      () => UpdateService.parseUpdateRelease(
        metadata([setupName]),
        installed: true,
      ),
      throwsA(isA<UpdateException>()),
    );
  });

  test('unsafe asset filenames cannot become download paths', () {
    expect(
      () => UpdateService.parseUpdateRelease(
        metadata([
          'AV-Network-Toolbag-../../payload-windows-x64-Setup.exe',
          'SHA256SUMS.txt',
        ]),
        installed: true,
      ),
      throwsA(isA<UpdateException>()),
    );
  });

  test(
    'installation marker is location-bound and supports UTF-8 BOM',
    () async {
      final root = await Directory.systemTemp.createTemp('avnt-update-test-');
      addTearDown(() => root.delete(recursive: true));
      expect(await isInstallerManaged(root), isFalse);
      final marker = File('${root.path}/$installationMarkerName');
      await marker.writeAsString('\ufeff${root.absolute.path}\r\n');
      expect(await isInstallerManaged(root), isTrue);
      final moved = await Directory('${root.path}/moved').create();
      await marker.copy('${moved.path}/$installationMarkerName');
      expect(await isInstallerManaged(moved), isFalse);
    },
  );

  Future<void> prepare(bool installed, {bool corrupt = false}) async {
    final release = UpdateService.parseUpdateRelease(
      metadata([zipName, setupName, 'SHA256SUMS.txt']),
      installed: installed,
    );
    final archive = Archive()
      ..addFile(ArchiveFile('av_network_toolbag.exe', 2, [77, 90]))
      ..addFile(ArchiveFile('av_network_toolbag_updater.exe', 2, [77, 90]));
    final bytes = installed ? [77, 90, 1, 2, 3] : ZipEncoder().encode(archive);
    final checksum = sha256.convert(corrupt ? [0] : bytes).toString();
    final client = _Client({
      '/SHA256SUMS.txt': utf8.encode('$checksum  ${release.archiveName}\n'),
      '/${release.archiveName}': bytes,
    });
    final service = UpdateService(client: client);
    addTearDown(service.close);
    final future = service.prepareUpdate(release, onProgress: (_, _) {});
    if (corrupt) {
      await expectLater(future, throwsA(isA<UpdateException>()));
      return;
    }
    final prepared = await future;
    addTearDown(() => prepared.stagingDirectory.delete(recursive: true));
    if (installed) {
      expect(await prepared.installerFile!.readAsBytes(), bytes);
      expect(await prepared.payloadDirectory.list().isEmpty, isTrue);
    } else {
      expect(prepared.installerFile, isNull);
      expect(
        await File('${prepared.payloadDirectory.path}/av_network_toolbag.exe')
            .exists(),
        isTrue,
      );
    }
    expect(client.requested, ['/SHA256SUMS.txt', '/${release.archiveName}']);
  }

  test(
    'installer is verified and staged without ZIP extraction',
    () => prepare(true),
  );
  test(
    'portable update still verifies and extracts its ZIP',
    () => prepare(false),
  );
  test(
    'installer checksum mismatch stops the update',
    () => prepare(true, corrupt: true),
  );
  test(
    'ZIP checksum mismatch stops the update',
    () => prepare(false, corrupt: true),
  );

  test('handoff refuses a ZIP for an installed location', () async {
    final root = await Directory.systemTemp.createTemp('avnt-update-test-');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/$installationMarkerName')
        .writeAsString(root.absolute.path);
    final service = UpdateService(
      applicationDirectory: root,
      client: _Client({}),
    );
    addTearDown(service.close);
    final release = UpdateService.parseUpdateRelease(
      metadata([zipName, 'SHA256SUMS.txt']),
      installed: false,
    );
    await expectLater(
      service.launchInstaller(
        PreparedUpdate(
          release: release,
          stagingDirectory: root,
          payloadDirectory: root,
        ),
      ),
      throwsA(isA<UpdateException>()),
    );
  });
}

class _Client implements HttpClient {
  _Client(this.responses);
  final Map<String, List<int>> responses;
  final requested = <String>[];
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requested.add(url.path);
    return _Request(responses[url.path]!);
  }

  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Request implements HttpClientRequest {
  _Request(this.bytes);
  final List<int> bytes;
  @override
  HttpHeaders get headers => _Headers();
  @override
  Future<HttpClientResponse> close() async => _Response(bytes);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Headers implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.bytes);
  final List<int> bytes;
  @override
  int get statusCode => 200;
  @override
  int get contentLength => bytes.length;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
