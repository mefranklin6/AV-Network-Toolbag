import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const _ipSuccess = 0;
const _icmpPayloadSize = 24;
const _icmpReplyBufferSize = 256;
const _maxPhysicalAddressLength = 8;
const _mibIpNetRowSize = 24;

typedef _IcmpCreateFileNative = IntPtr Function();
typedef _IcmpCreateFileDart = int Function();

typedef _IcmpSendEcho2ExNative = Uint32 Function(
  IntPtr icmpHandle,
  IntPtr event,
  IntPtr apcRoutine,
  IntPtr apcContext,
  Uint32 sourceAddress,
  Uint32 destinationAddress,
  Pointer<Void> requestData,
  Uint16 requestSize,
  Pointer<Void> requestOptions,
  Pointer<Void> replyBuffer,
  Uint32 replySize,
  Uint32 timeout,
);
typedef _IcmpSendEcho2ExDart = int Function(
  int icmpHandle,
  int event,
  int apcRoutine,
  int apcContext,
  int sourceAddress,
  int destinationAddress,
  Pointer<Void> requestData,
  int requestSize,
  Pointer<Void> requestOptions,
  Pointer<Void> replyBuffer,
  int replySize,
  int timeout,
);

typedef _IcmpCloseHandleNative = Int32 Function(IntPtr icmpHandle);
typedef _IcmpCloseHandleDart = int Function(int icmpHandle);

typedef _GetIpNetTableNative = Uint32 Function(
  Pointer<Void> table,
  Pointer<Uint32> size,
  Int32 order,
);
typedef _GetIpNetTableDart = int Function(
  Pointer<Void> table,
  Pointer<Uint32> size,
  int order,
);

typedef _DnsQueryNative = Int32 Function(
  Pointer<Utf16> name,
  Uint16 type,
  Uint32 options,
  Pointer<Void> extra,
  Pointer<Pointer<Void>> results,
  Pointer<Pointer<Void>> reserved,
);
typedef _DnsQueryDart = int Function(
  Pointer<Utf16> name,
  int type,
  int options,
  Pointer<Void> extra,
  Pointer<Pointer<Void>> results,
  Pointer<Pointer<Void>> reserved,
);

typedef _DnsRecordListFreeNative = Void Function(
  Pointer<Void> records,
  Int32 freeType,
);
typedef _DnsRecordListFreeDart = void Function(
  Pointer<Void> records,
  int freeType,
);

final class _IpHelperApi {
  _IpHelperApi._() : _library = DynamicLibrary.open('iphlpapi.dll') {
    icmpCreateFile = _library
        .lookupFunction<_IcmpCreateFileNative, _IcmpCreateFileDart>(
          'IcmpCreateFile',
        );
    icmpSendEcho2Ex = _library
        .lookupFunction<_IcmpSendEcho2ExNative, _IcmpSendEcho2ExDart>(
          'IcmpSendEcho2Ex',
        );
    icmpCloseHandle = _library
        .lookupFunction<_IcmpCloseHandleNative, _IcmpCloseHandleDart>(
          'IcmpCloseHandle',
        );
    getIpNetTable = _library
        .lookupFunction<_GetIpNetTableNative, _GetIpNetTableDart>(
          'GetIpNetTable',
        );
  }

  static final instance = _IpHelperApi._();

  // Retaining the library explicitly documents the lifetime of the symbols.
  final DynamicLibrary _library;
  late final _IcmpCreateFileDart icmpCreateFile;
  late final _IcmpSendEcho2ExDart icmpSendEcho2Ex;
  late final _IcmpCloseHandleDart icmpCloseHandle;
  late final _GetIpNetTableDart getIpNetTable;
}

final class _WindowsDnsApi {
  _WindowsDnsApi._() : _library = DynamicLibrary.open('dnsapi.dll') {
    query = _library.lookupFunction<_DnsQueryNative, _DnsQueryDart>(
      'DnsQuery_W',
    );
    freeRecords = _library
        .lookupFunction<_DnsRecordListFreeNative, _DnsRecordListFreeDart>(
          'DnsRecordListFree',
        );
  }

  static final instance = _WindowsDnsApi._();

  final DynamicLibrary _library;
  late final _DnsQueryDart query;
  late final _DnsRecordListFreeDart freeRecords;
}

/// Worker entry point for a fixed native-ICMP scan worker.
///
/// Messages sent to [resultPort] are small sendable lists:
/// `['ready', workerId, SendPort]`, `['result', address, replied]`, and
/// `['done', workerId]`. The control port accepts the string `stop`.
Future<void> windowsIcmpScanWorker(Map<String, Object> arguments) async {
  final resultPort = arguments['resultPort']! as SendPort;
  final workerId = arguments['workerId']! as int;
  final sourceAddress = arguments['sourceAddress']! as String;
  final addresses = (arguments['addresses']! as List).cast<String>();
  final timeoutMilliseconds = arguments['timeoutMilliseconds']! as int;
  final control = ReceivePort();
  var stopRequested = false;
  control.listen((message) {
    if (message == 'stop') stopRequested = true;
  });
  resultPort.send(['ready', workerId, control.sendPort]);

  _NativeIcmpSession? session;
  try {
    session = _NativeIcmpSession(sourceAddress);
    for (final address in addresses) {
      if (stopRequested) break;
      final replied = session.ping(address, timeoutMilliseconds);
      resultPort.send(['result', address, replied]);
      // IcmpSendEcho2Ex is synchronous here. Yield so a pending stop message is
      // handled between addresses without requiring forceful isolate shutdown.
      await Future<void>.delayed(Duration.zero);
    }
  } on Object catch (error) {
    resultPort.send(['error', workerId, error.toString()]);
  } finally {
    session?.close();
    control.close();
    resultPort.send(['done', workerId]);
  }
}

/// Worker entry point for bounded Windows PTR lookups.
Future<void> windowsHostnameWorker(Map<String, Object> arguments) async {
  final resultPort = arguments['resultPort']! as SendPort;
  final workerId = arguments['workerId']! as int;
  final addresses = (arguments['addresses']! as List).cast<String>();
  final control = ReceivePort();
  var stopRequested = false;
  control.listen((message) {
    if (message == 'stop') stopRequested = true;
  });
  resultPort.send(['ready', workerId, control.sendPort]);

  try {
    for (final address in addresses) {
      if (stopRequested) break;
      final hostname = _lookupPtrRecord(address) ?? '(no PTR record)';
      resultPort.send(['hostname', address, hostname]);
      await Future<void>.delayed(Duration.zero);
    }
  } on Object catch (error) {
    resultPort.send(['error', workerId, error.toString()]);
  } finally {
    control.close();
    resultPort.send(['done', workerId]);
  }
}

final class _NativeIcmpSession {
  _NativeIcmpSession(String sourceAddress)
    : _sourceAddress = _ipv4ToNative(sourceAddress),
      _handle = _IpHelperApi.instance.icmpCreateFile(),
      _request = calloc<Uint8>(_icmpPayloadSize),
      _reply = calloc<Uint8>(_icmpReplyBufferSize) {
    if (_handle == 0 || _handle == -1) {
      close();
      throw StateError('Windows could not create an ICMP handle.');
    }
    for (var index = 0; index < _icmpPayloadSize; index++) {
      _request[index] = 0x41 + (index % 26);
    }
  }

  final int _sourceAddress;
  int _handle;
  final Pointer<Uint8> _request;
  final Pointer<Uint8> _reply;
  bool _closed = false;

  bool ping(String destinationAddress, int timeoutMilliseconds) {
    if (_closed) return false;
    _reply
        .asTypedList(_icmpReplyBufferSize)
        .fillRange(0, _icmpReplyBufferSize, 0);
    final replies = _IpHelperApi.instance.icmpSendEcho2Ex(
      _handle,
      0,
      0,
      0,
      _sourceAddress,
      _ipv4ToNative(destinationAddress),
      _request.cast(),
      _icmpPayloadSize,
      nullptr,
      _reply.cast(),
      _icmpReplyBufferSize,
      timeoutMilliseconds,
    );
    if (replies == 0) return false;
    final status = _reply.cast<Uint32>()[1];
    return status == _ipSuccess;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_handle != 0 && _handle != -1) {
      _IpHelperApi.instance.icmpCloseHandle(_handle);
      _handle = 0;
    }
    calloc
      ..free(_request)
      ..free(_reply);
  }
}

/// Returns IPv4-to-MAC mappings from Windows' neighbor table for one adapter.
Map<String, String> queryWindowsIpv4Neighbors(int interfaceIndex) {
  final api = _IpHelperApi.instance;
  final size = calloc<Uint32>();
  Pointer<Uint8>? table;
  try {
    api.getIpNetTable(nullptr, size, 0);
    if (size.value < 4) return const {};
    table = calloc<Uint8>(size.value);
    final result = api.getIpNetTable(table.cast(), size, 0);
    if (result != 0) {
      throw StateError('GetIpNetTable failed with Windows error $result.');
    }

    final bytes = table.asTypedList(size.value);
    final data = ByteData.sublistView(bytes);
    final count = data.getUint32(0, Endian.little);
    final neighbors = <String, String>{};
    for (var index = 0; index < count; index++) {
      final offset = 4 + (index * _mibIpNetRowSize);
      if (offset + _mibIpNetRowSize > bytes.length) break;
      final rowInterface = data.getUint32(offset, Endian.little);
      final physicalLength = data.getUint32(offset + 4, Endian.little);
      if (rowInterface != interfaceIndex ||
          physicalLength != 6 ||
          physicalLength > _maxPhysicalAddressLength) {
        continue;
      }
      final macBytes = bytes.sublist(offset + 8, offset + 8 + physicalLength);
      if (macBytes.every((value) => value == 0) ||
          macBytes.every((value) => value == 0xff)) {
        continue;
      }
      final address = bytes.sublist(offset + 16, offset + 20).join('.');
      final mac = macBytes
          .map((value) => value.toRadixString(16).padLeft(2, '0'))
          .join('-')
          .toUpperCase();
      neighbors[address] = mac;
    }
    return neighbors;
  } finally {
    if (table != null) calloc.free(table);
    calloc.free(size);
  }
}

String? _lookupPtrRecord(String address) {
  const dnsTypePtr = 12;
  const dnsFreeRecordList = 1;
  final parts = address.split('.');
  if (parts.length != 4) return null;
  final queryName = '${parts.reversed.join('.')}.in-addr.arpa'.toNativeUtf16();
  final records = calloc<Pointer<Void>>();
  try {
    final status = _WindowsDnsApi.instance.query(
      queryName,
      dnsTypePtr,
      0,
      nullptr,
      records,
      nullptr,
    );
    if (status != 0 || records.value.address == 0) return null;

    var record = records.value;
    while (record.address != 0) {
      final bytes = record.cast<Uint8>();
      final type = (bytes + 16).cast<Uint16>().value;
      if (type == dnsTypePtr) {
        final host = (bytes + 32).cast<Pointer<Utf16>>().value;
        if (host.address != 0) {
          final value = host.toDartString().trim();
          if (value.isNotEmpty) {
            return value.endsWith('.')
                ? value.substring(0, value.length - 1)
                : value;
          }
        }
      }
      record = record.cast<Pointer<Void>>().value;
    }
    return null;
  } finally {
    if (records.value.address != 0) {
      _WindowsDnsApi.instance.freeRecords(records.value, dnsFreeRecordList);
    }
    calloc
      ..free(records)
      ..free(queryName);
  }
}

int _ipv4ToNative(String address) {
  final parts = address.split('.').map(int.parse).toList();
  if (parts.length != 4 || parts.any((value) => value < 0 || value > 255)) {
    throw FormatException('Invalid IPv4 address: $address');
  }
  return parts[0] | (parts[1] << 8) | (parts[2] << 16) | (parts[3] << 24);
}
