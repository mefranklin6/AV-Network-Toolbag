import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

const _latestReleaseApi =
    'https://api.github.com/repos/mefranklin6/AV-Network-Toolbag/releases/latest';
const latestReleasePage =
    'https://github.com/mefranklin6/AV-Network-Toolbag/releases/latest';
const _releaseArchivePattern =
    r'^AV-Network-Toolbag-[0-9A-Za-z._-]+-windows-x64\.zip$';
const _releaseInstallerPattern =
    r'^AV-Network-Toolbag-[0-9A-Za-z._-]+-windows-x64-Setup\.exe$';
const installationMarkerName = 'installed.location';
const _maximumArchiveBytes = 500 * 1024 * 1024;
const _maximumExpandedBytes = 1024 * 1024 * 1024;

class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class UpdateRelease {
  const UpdateRelease({
    required this.version,
    required this.tag,
    required this.name,
    required this.notes,
    required this.pageUrl,
    required this.archiveName,
    required this.archiveUrl,
    required this.checksumUrl,
    this.installer = false,
  });

  final String version;
  final String tag;
  final String name;
  final String notes;
  final Uri pageUrl;
  final String archiveName;
  final Uri archiveUrl;
  final Uri checksumUrl;
  final bool installer;

  bool isNewerThan(String currentVersion) =>
      _SemanticVersion.parse(version)
          .compareTo(_SemanticVersion.parse(currentVersion)) >
      0;
}

class PreparedUpdate {
  const PreparedUpdate({
    required this.release,
    required this.stagingDirectory,
    required this.payloadDirectory,
    this.installerFile,
  });

  final UpdateRelease release;
  final Directory stagingDirectory;
  final Directory payloadDirectory;
  final File? installerFile;
}

class UpdateService {
  UpdateService({Directory? applicationDirectory, HttpClient? client})
    : applicationDirectory =
          applicationDirectory ?? File(Platform.resolvedExecutable).parent,
      _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 12);
    _client.idleTimeout = const Duration(seconds: 15);
    _client.userAgent = 'AV-Network-Toolbag-Updater';
  }

  final HttpClient _client;
  final Directory applicationDirectory;

  Future<UpdateRelease?> checkForUpdate(String currentVersion) async {
    final release = await fetchLatestRelease();
    return release.isNewerThan(currentVersion) ? release : null;
  }

  Future<UpdateRelease> fetchLatestRelease() async {
    final response = await _get(Uri.parse(_latestReleaseApi));
    final body = await _readResponseText(
      response,
      maximumBytes: 2 * 1024 * 1024,
    );
    if (response.statusCode != HttpStatus.ok) {
      throw UpdateException(
        'GitHub returned HTTP ${response.statusCode} while checking for updates.',
      );
    }
    final value = jsonDecode(body);
    if (value is! Map<String, dynamic>) {
      throw const UpdateException(
        'GitHub returned an invalid release response.',
      );
    }
    return parseUpdateRelease(
      value,
      installed: await isInstallerManaged(applicationDirectory),
    );
  }

  static UpdateRelease parseUpdateRelease(
    Map<String, dynamic> value, {
    required bool installed,
  }) {
    final tag = value['tag_name']?.toString().trim() ?? '';
    final version = _SemanticVersion.normalized(tag);
    final pageUrl = Uri.tryParse(value['html_url']?.toString() ?? '');
    if (version.isEmpty || pageUrl == null || pageUrl.scheme != 'https') {
      throw const UpdateException(
        'The latest GitHub release has invalid metadata.',
      );
    }

    String? archiveName;
    Uri? archiveUrl;
    Uri? checksumUrl;
    final assets = value['assets'];
    if (assets is List) {
      for (final asset in assets.whereType<Map>()) {
        final name = asset['name']?.toString() ?? '';
        final url = Uri.tryParse(
          asset['browser_download_url']?.toString() ?? '',
        );
        if (url == null || url.scheme != 'https') continue;
        if (RegExp(
          installed ? _releaseInstallerPattern : _releaseArchivePattern,
        ).hasMatch(name)) {
          archiveName = name;
          archiveUrl = url;
        } else if (name.toUpperCase() == 'SHA256SUMS.TXT') {
          checksumUrl = url;
        }
      }
    }
    if (archiveName == null || archiveUrl == null || checksumUrl == null) {
      throw UpdateException(
        'The latest release does not contain both the Windows '
        '${installed ? 'installer' : 'ZIP'} and SHA256SUMS.txt.',
      );
    }
    return UpdateRelease(
      version: version,
      tag: tag,
      name: value['name']?.toString().trim().isNotEmpty == true
          ? value['name'].toString().trim()
          : tag,
      notes: value['body']?.toString().trim() ?? '',
      pageUrl: pageUrl,
      archiveName: archiveName,
      archiveUrl: archiveUrl,
      checksumUrl: checksumUrl,
      installer: installed,
    );
  }

  Future<PreparedUpdate> prepareUpdate(
    UpdateRelease release, {
    required void Function(double? progress, String activity) onProgress,
  }) async {
    final staging = await Directory.systemTemp.createTemp(
      'AVNetworkToolbag-update-',
    );
    final payload = Directory(
      '${staging.path}${Platform.pathSeparator}payload',
    );
    await payload.create(recursive: true);
    try {
      onProgress(null, 'Downloading release checksum…');
      final checksumResponse = await _get(release.checksumUrl);
      final checksumText = await _readResponseText(
        checksumResponse,
        maximumBytes: 1024 * 1024,
      );
      if (checksumResponse.statusCode != HttpStatus.ok) {
        throw UpdateException(
          'GitHub returned HTTP ${checksumResponse.statusCode} for the checksum.',
        );
      }
      final expectedHash = _checksumFor(checksumText, release.archiveName);
      if (expectedHash == null) {
        throw UpdateException(
          'SHA256SUMS.txt does not contain ${release.archiveName}.',
        );
      }

      final archiveFile = File(
        '${staging.path}${Platform.pathSeparator}${release.archiveName}',
      );
      onProgress(0, 'Downloading ${release.archiveName}…');
      await _downloadFile(
        release.archiveUrl,
        archiveFile,
        maximumBytes: _maximumArchiveBytes,
        onProgress: (progress) =>
            onProgress(progress, 'Downloading ${release.archiveName}…'),
      );

      onProgress(null, 'Verifying SHA-256 checksum…');
      final actualHash = (await sha256.bind(archiveFile.openRead()).first)
          .toString()
          .toLowerCase();
      if (actualHash != expectedHash.toLowerCase()) {
        throw const UpdateException(
          'The downloaded update failed SHA-256 verification.',
        );
      }

      if (release.installer) {
        return PreparedUpdate(
          release: release,
          stagingDirectory: staging,
          payloadDirectory: payload,
          installerFile: archiveFile,
        );
      }

      onProgress(null, 'Extracting and validating the update…');
      await _extractSafely(archiveFile, payload);
      final executable = File(
        '${payload.path}${Platform.pathSeparator}av_network_toolbag.exe',
      );
      final helper = File(
        '${payload.path}${Platform.pathSeparator}'
        'av_network_toolbag_updater.exe',
      );
      if (!await executable.exists() || !await helper.exists()) {
        throw const UpdateException(
          'The update archive is missing required application files.',
        );
      }
      return PreparedUpdate(
        release: release,
        stagingDirectory: staging,
        payloadDirectory: payload,
      );
    } on Object {
      try {
        if (await staging.exists()) await staging.delete(recursive: true);
      } on Object {
        // The original update error is more useful than cleanup failure.
      }
      rethrow;
    }
  }

  Future<void> launchInstaller(PreparedUpdate update) async {
    final installDirectory = applicationDirectory;
    final installed = await isInstallerManaged(installDirectory);
    if (installed != update.release.installer) {
      throw const UpdateException(
        'The installation type changed. Check for updates again.',
      );
    }
    final bundledHelper = File(
      '${installed ? installDirectory.path : update.payloadDirectory.path}${Platform.pathSeparator}'
      'av_network_toolbag_updater.exe',
    );
    final temporaryHelper = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'AVNetworkToolbagUpdater-${DateTime.now().microsecondsSinceEpoch}.exe',
    );
    await bundledHelper.copy(temporaryHelper.path);
    await Process.start(
      temporaryHelper.path,
      [
        pid.toString(),
        installed ? update.installerFile!.path : update.payloadDirectory.path,
        update.stagingDirectory.path,
        installDirectory.path,
        installed ? '--installer' : 'av_network_toolbag.exe',
      ],
      mode: ProcessStartMode.detached,
      workingDirectory: Directory.systemTemp.path,
    );
  }

  void close() => _client.close(force: true);

  Future<HttpClientResponse> _get(Uri uri) async {
    if (uri.scheme != 'https') {
      throw const UpdateException('Update downloads must use HTTPS.');
    }
    final request = await _client
        .getUrl(uri)
        .timeout(const Duration(seconds: 15));
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
      ..set('X-GitHub-Api-Version', '2022-11-28');
    return request.close().timeout(const Duration(seconds: 20));
  }

  Future<String> _readResponseText(
    HttpClientResponse response, {
    required int maximumBytes,
  }) async {
    final output = BytesBuilder(copy: false);
    var received = 0;
    await for (final chunk in response.timeout(const Duration(seconds: 20))) {
      received += chunk.length;
      if (received > maximumBytes) {
        throw const UpdateException(
          'The update response was unexpectedly large.',
        );
      }
      output.add(chunk);
    }
    return utf8.decode(output.takeBytes(), allowMalformed: true);
  }

  Future<void> _downloadFile(
    Uri uri,
    File destination, {
    required int maximumBytes,
    required void Function(double? progress) onProgress,
  }) async {
    final response = await _get(uri);
    if (response.statusCode != HttpStatus.ok) {
      throw UpdateException(
        'GitHub returned HTTP ${response.statusCode} for the update download.',
      );
    }
    final declaredLength = response.contentLength;
    if (declaredLength > maximumBytes) {
      throw const UpdateException('The update archive is unexpectedly large.');
    }
    final sink = destination.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        received += chunk.length;
        if (received > maximumBytes) {
          throw const UpdateException(
            'The update archive exceeded the size limit.',
          );
        }
        sink.add(chunk);
        onProgress(declaredLength > 0 ? received / declaredLength : null);
      }
    } finally {
      await sink.close();
    }
  }

  Future<void> _extractSafely(File archiveFile, Directory payload) async {
    final input = InputFileStream(archiveFile.path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      if (archive.length > 10000) {
        throw const UpdateException(
          'The update archive contains too many files.',
        );
      }
      var expandedBytes = 0;
      for (final entry in archive) {
        final path = entry.name.replaceAll('\\', '/');
        final parts = path.split('/').where((part) => part.isNotEmpty).toList();
        if (path.startsWith('/') ||
            parts.isEmpty ||
            parts.any((part) => part == '..' || part.contains(':')) ||
            entry.isSymbolicLink) {
          throw const UpdateException(
            'The update archive contains an unsafe path.',
          );
        }
        expandedBytes += entry.size;
        if (expandedBytes > _maximumExpandedBytes) {
          throw const UpdateException(
            'The extracted update is unexpectedly large.',
          );
        }
        final outputPath =
            '${payload.path}${Platform.pathSeparator}'
            '${parts.join(Platform.pathSeparator)}';
        if (entry.isFile) {
          await File(outputPath).parent.create(recursive: true);
          final output = OutputFileStream(outputPath);
          try {
            entry.writeContent(output);
          } finally {
            output.closeSync();
          }
        } else {
          await Directory(outputPath).create(recursive: true);
        }
      }
    } finally {
      input.closeSync();
    }
  }
}

/// Inno writes the destination path as UTF-8. A copy moved elsewhere is portable.
Future<bool> isInstallerManaged(Directory directory) async {
  final marker = File(
    '${directory.path}${Platform.pathSeparator}$installationMarkerName',
  );
  if (!await marker.exists()) return false;
  // Do not silently fall back to ZIP updates if an installed marker is unreadable.
  final recorded = (await marker.readAsString())
      .replaceFirst('\ufeff', '')
      .trim();
  String normalize(String path) => path
      .replaceAll('/', r'\')
      .replaceFirst(RegExp(r'\\+$'), '')
      .toLowerCase();
  return normalize(recorded) == normalize(directory.absolute.path);
}

String readExecutableVersion() {
  if (!Platform.isWindows) return '0.0.0';
  final filename = Platform.resolvedExecutable.toNativeUtf16();
  Pointer<Uint8>? buffer;
  final valuePointer = calloc<Pointer>();
  final valueLength = calloc<Uint32>();
  final root = r'\'.toNativeUtf16();
  try {
    final size = GetFileVersionInfoSize(PCWSTR(filename), null).value;
    if (size <= 0) return '0.0.0';
    buffer = calloc<Uint8>(size);
    if (!GetFileVersionInfo(PCWSTR(filename), size, buffer.cast()).value ||
        !VerQueryValue(
          buffer.cast(),
          PCWSTR(root),
          valuePointer,
          valueLength,
        ) ||
        valueLength.value < sizeOf<VS_FIXEDFILEINFO>()) {
      return '0.0.0';
    }
    final info = valuePointer.value.cast<VS_FIXEDFILEINFO>().ref;
    final major = (info.dwFileVersionMS >> 16) & 0xffff;
    final minor = info.dwFileVersionMS & 0xffff;
    final patch = (info.dwFileVersionLS >> 16) & 0xffff;
    return '$major.$minor.$patch';
  } finally {
    if (buffer != null) calloc.free(buffer);
    calloc
      ..free(filename)
      ..free(valuePointer)
      ..free(valueLength)
      ..free(root);
  }
}

String? _checksumFor(String contents, String filename) {
  for (final line in const LineSplitter().convert(contents)) {
    final match = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$').firstMatch(line);
    if (match != null && match.group(2)!.trim() == filename) {
      return match.group(1);
    }
  }
  return null;
}

class _SemanticVersion implements Comparable<_SemanticVersion> {
  const _SemanticVersion(this.parts, this.prerelease);

  factory _SemanticVersion.parse(String value) {
    final normalizedValue = normalized(value);
    final split = normalizedValue.split('-');
    final numbers = split.first.split('.').map(int.tryParse).toList();
    if (numbers.isEmpty || numbers.any((part) => part == null)) {
      throw UpdateException('Invalid version: $value');
    }
    return _SemanticVersion(
      numbers.cast<int>(),
      split.length > 1 ? split.sublist(1).join('-') : '',
    );
  }

  static String normalized(String value) =>
      value.trim().replaceFirst(RegExp(r'^[vV]'), '').split('+').first;

  final List<int> parts;
  final String prerelease;

  @override
  int compareTo(_SemanticVersion other) {
    final length = parts.length > other.parts.length
        ? parts.length
        : other.parts.length;
    for (var index = 0; index < length; index++) {
      final left = index < parts.length ? parts[index] : 0;
      final right = index < other.parts.length ? other.parts[index] : 0;
      if (left != right) return left.compareTo(right);
    }
    if (prerelease.isEmpty != other.prerelease.isEmpty) {
      return prerelease.isEmpty ? 1 : -1;
    }
    return prerelease.compareTo(other.prerelease);
  }
}
