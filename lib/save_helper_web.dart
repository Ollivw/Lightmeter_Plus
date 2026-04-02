import 'dart:typed_data';
import 'dart:js_interop';
import 'package:web/web.dart' as web;

/// Triggert einen Browser-Download für Web-Plattformen
Future<bool> saveProjectFile(Uint8List bytes, String fileName) async {
  final blob = web.Blob([bytes.toJS].toJS);
  final url = web.URL.createObjectURL(blob);
  
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement;
  anchor.href = url;
  anchor.setAttribute('download', fileName);
  anchor.click();
  
  web.URL.revokeObjectURL(url);
  return true;
}
