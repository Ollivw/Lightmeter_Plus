import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:printing/printing.dart'; // Für stabiles PDF-Rendering

void main() => runApp(
  const MaterialApp(home: PdfMarkerWidget(), debugShowCheckedModeBanner: false),
);

class PdfMarkerWidget extends StatefulWidget {
  const PdfMarkerWidget({super.key});
  @override
  State<PdfMarkerWidget> createState() => _PdfMarkerWidgetState();
}

class _PdfMarkerWidgetState extends State<PdfMarkerWidget> {
  Uint8List? _pageImageBytes;
  final List<Offset> _markers = [];
  double _pixelsPerMeter = 1.0; // Standardmäßig 1:1

  // Gummiband / Kalibrierung
  Offset? _calibStart, _calibEnd, _mousePos;
  bool _isCalibrating = false;

  Future<void> _pickPdfFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );

    if (result != null && result.files.single.path != null) {
      final fileBytes = await File(result.files.single.path!).readAsBytes();

      // Nutzt 'printing' um die PDF Seite 1 als Bild zu rastern (sehr stabil)
      await for (var page in Printing.raster(fileBytes, pages: [0], dpi: 300)) {
        final pngBytes = await page.toPng();
        setState(() {
          _pageImageBytes = pngBytes;
          _markers.clear();
          _calibStart = null;
          _calibEnd = null;
          _isCalibrating = false;
        });
        break;
      }
    }
  }

  void _handleTap(TapDownDetails details) {
    if (_isCalibrating) {
      if (_calibStart == null) {
        setState(() => _calibStart = details.localPosition);
      } else if (_calibEnd == null) {
        setState(() => _calibEnd = details.localPosition);
        _showCalibDialog();
      }
    } else {
      setState(() => _markers.add(details.localPosition));
    }
  }

  void _showCalibDialog() {
    TextEditingController ctrl = TextEditingController(text: "5.0");
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text("Maßstab festlegen"),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: "Länge in Metern",
            suffixText: "m",
          ),
          keyboardType: TextInputType.number,
        ),
        actions: [
          TextButton(
            onPressed: () {
              double realDist = double.tryParse(ctrl.text) ?? 5.0;
              double pixelDist = (_calibEnd! - _calibStart!).distance;
              setState(() {
                _pixelsPerMeter = pixelDist / realDist;
                _isCalibrating = false;
              });
              Navigator.pop(ctx);
            },
            child: const Text("OK"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lightmeter PDF Marker'),
        actions: [
          IconButton(
            icon: Icon(
              Icons.straighten,
              color: _isCalibrating ? Colors.orange : Colors.grey,
            ),
            onPressed: () => setState(() {
              _isCalibrating = !_isCalibrating;
              _calibStart = null;
              _calibEnd = null;
            }),
            tooltip: 'Kalibrieren (Gummiband)',
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () => setState(() => _markers.clear()),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_pageImageBytes == null)
            Expanded(
              child: Center(
                child: ElevatedButton(
                  onPressed: _pickPdfFile,
                  child: const Text('PDF laden'),
                ),
              ),
            )
          else
            Expanded(
              child: MouseRegion(
                onHover: (e) => setState(() => _mousePos = e.localPosition),
                child: GestureDetector(
                  onTapDown: _handleTap,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.memory(_pageImageBytes!, fit: BoxFit.contain),
                      CustomPaint(
                        painter: _MarkerPainter(
                          _markers,
                          _calibStart,
                          _calibEnd,
                          _mousePos,
                          _isCalibrating,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_markers.isNotEmpty)
            Container(
              height: 120,
              color: Colors.white,
              child: ListView.builder(
                itemCount: _markers.length,
                itemBuilder: (ctx, i) {
                  double xM = _markers[i].dx / _pixelsPerMeter;
                  double yM = _markers[i].dy / _pixelsPerMeter;
                  return ListTile(
                    dense: true,
                    title: Text(
                      'Punkt ${i + 1}: ${xM.toStringAsFixed(2)}m / ${yM.toStringAsFixed(2)}m',
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _MarkerPainter extends CustomPainter {
  final List<Offset> markers;
  final Offset? cStart, cEnd, mPos;
  final bool isCalib;

  _MarkerPainter(this.markers, this.cStart, this.cEnd, this.mPos, this.isCalib);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.fill;

    // Zeichne Messpunkte
    for (final marker in markers) {
      canvas.drawCircle(marker, 6, paint);
    }

    // Gummiband Kalibrierung
    if (isCalib && cStart != null) {
      final calibPaint = Paint()
        ..color = Colors.orange
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke;
      canvas.drawLine(cStart!, cEnd ?? mPos ?? cStart!, calibPaint);
      canvas.drawCircle(cStart!, 5, calibPaint..style = PaintingStyle.fill);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
