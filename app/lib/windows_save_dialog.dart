import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

String? showCsvSaveDialog(
  String suggestedName, {
  String title = 'Export Subnet Scan',
}) {
  final dialog = calloc<OPENFILENAME>();
  final fileBuffer = calloc<Uint16>(32768);
  final filter = _utf16Buffer(
    'CSV files (*.csv)\x00*.csv\x00All files (*.*)\x00*.*\x00\x00',
  );
  final titleBuffer = _utf16Buffer(title);
  final extension = _utf16Buffer('csv');
  try {
    PWSTR(fileBuffer.cast()).setString(suggestedName);
    dialog.ref
      ..lStructSize = sizeOf<OPENFILENAME>()
      ..hwndOwner = GetActiveWindow()
      ..lpstrFilter = PWSTR(filter.cast())
      ..nFilterIndex = 1
      ..lpstrFile = PWSTR(fileBuffer.cast())
      ..nMaxFile = 32768
      ..lpstrTitle = PWSTR(titleBuffer.cast())
      ..Flags = const OPEN_FILENAME_FLAGS(
        0x00000002 | // OFN_OVERWRITEPROMPT
            0x00000008 | // OFN_NOCHANGEDIR
            0x00000800, // OFN_PATHMUSTEXIST
      )
      ..lpstrDefExt = PWSTR(extension.cast());
    if (!GetSaveFileName(dialog)) return null;
    return PWSTR(fileBuffer.cast()).toDartString();
  } finally {
    calloc.free(extension);
    calloc.free(titleBuffer);
    calloc.free(filter);
    calloc.free(fileBuffer);
    calloc.free(dialog);
  }
}

Pointer<Uint16> _utf16Buffer(String value) {
  final buffer = calloc<Uint16>(value.codeUnits.length + 1);
  buffer.asTypedList(value.codeUnits.length + 1).setAll(0, value.codeUnits);
  return buffer;
}
