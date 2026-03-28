import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';

/// Nutzt den FilePicker und dart:io für Windows/Android
Future<bool> saveProjectFile(Uint8List bytes, String fileName) async {
  String? outputPath = await FilePicker.platform.saveFile(
    dialogTitle: 'Projekt speichern',
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: ['lmp'],
  );

  if (outputPath != null) {
    final file = File(outputPath);
    await file.writeAsBytes(bytes);
    return true;
  }
  return false;
}
