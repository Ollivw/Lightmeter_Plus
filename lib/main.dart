import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:printing/printing.dart'; // Für stabiles PDF-Rendering
import 'save_helper.dart' if (dart.library.html) 'save_helper_web.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: const LightmeterApp(),
    ),
  );
}

class MeasurementMarker {
  Offset position;
  String label;
  double height;
  double? sensorValue;

  MeasurementMarker({
    required this.position,
    this.label = '',
    this.height = 0.8,
    this.sensorValue,
  });

  Map<String, dynamic> toJson() => {
    'dx': position.dx,
    'dy': position.dy,
    'label': label,
    'height': height,
    'sensorValue': sensorValue,
  };

  factory MeasurementMarker.fromJson(Map<String, dynamic> json) =>
      MeasurementMarker(
        position: Offset(
          (json['dx'] as num).toDouble(),
          (json['dy'] as num).toDouble(),
        ),
        label: json['label'],
        height: (json['height'] as num).toDouble(),
        sensorValue: json['sensorValue'] != null
            ? (json['sensorValue'] as num).toDouble()
            : null,
      );
}

class ThemeProvider with ChangeNotifier {
  bool _isDarkMode = false;
  Color _backgroundColor = const Color(0xFFF5F5F5);

  bool get isDarkMode => _isDarkMode;
  Color get backgroundColor => _backgroundColor;

  void toggleTheme() {
    _isDarkMode = !_isDarkMode;
    notifyListeners();
  }

  void setBackgroundColor(Color color) {
    _backgroundColor = color;
    notifyListeners();
  }

  ThemeData get theme => ThemeData(
    useMaterial3: true,
    brightness: _isDarkMode ? Brightness.dark : Brightness.light,
    primaryColor: const Color(0xFF263238),
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF263238),
      brightness: _isDarkMode ? Brightness.dark : Brightness.light,
    ),
    scaffoldBackgroundColor: backgroundColor,
    appBarTheme: AppBarTheme(
      backgroundColor: _isDarkMode
          ? const Color(0xFF263238)
          : Colors.blueGrey[700],
      foregroundColor: Colors.white,
    ),
  );
}

class LightmeterApp extends StatelessWidget {
  const LightmeterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, child) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: themeProvider.theme,
          darkTheme: themeProvider.theme,
          home: const HomeScreen(),
        );
      },
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _pdfPath;
  bool _isLoading = false;
  Uint8List? _pdfBytes;
  Size? _pdfSize;
  Size?
  _viewportSize; // New: To store the size of the InteractiveViewer's parent

  final GlobalKey _pdfKey = GlobalKey();
  // Project Information
  String _projectName = '';
  String _surveyorName = '';
  String _usedDevices = '';
  String _additionalNotes = '';

  // Grid Settings
  bool _showGrid = false;
  bool _snapToGrid = false;
  double _gridSizeX = 2.0;
  double _gridSizeY = 2.0;
  Offset _gridOffset = Offset.zero;
  bool _isMovingGrid = false;

  final List<MeasurementMarker> _measurementPoints = [];
  bool _isCalibrating = false;
  Offset? _calibrationStart;
  Offset? _calibrationEnd;
  Offset? _currentMousePosition;
  double _pixelsPerMeter = 100.0;
  double _markerSize = 24.0;
  Offset _dragPositionAccumulator = Offset.zero;
  final TransformationController _transformationController =
      TransformationController();

  Future<void> _confirmReset() async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Neustart bestätigen'),
        content: const Text(
          'Möchten Sie wirklich alle Messpunkte löschen und neu starten?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Bestätigen'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      setState(() {
        _pdfPath = null;
        _pdfBytes = null;
        _pdfSize = null;
        _measurementPoints.clear();
        _isCalibrating = false;
        _calibrationStart = null;
        _showGrid = false;
        _snapToGrid = false;
        _gridSizeX = 2.0;
        _gridSizeY = 2.0;
        _gridOffset = Offset.zero;
        _isMovingGrid = false;
        _projectName = '';
        _surveyorName = '';
        _usedDevices = '';
        _additionalNotes = '';
        _calibrationEnd = null;
        _currentMousePosition = null;
        _transformationController.value = Matrix4.identity();
      });
    }
  }

  void _fitPdfToScreen() {
    if (_pdfSize == null || _viewportSize == null) return;

    final double imageWidth = _pdfSize!.width;
    final double imageHeight = _pdfSize!.height;
    final double viewportWidth = _viewportSize!.width;
    final double viewportHeight = _viewportSize!.height;

    final double scaleX = viewportWidth / imageWidth;
    final double scaleY = viewportHeight / imageHeight;
    final double scale = min(scaleX, scaleY);

    final double scaledImageWidth = imageWidth * scale;
    final double scaledImageHeight = imageHeight * scale;

    final double translateX = (viewportWidth - scaledImageWidth) / 2;
    final double translateY = (viewportHeight - scaledImageHeight) / 2;

    _transformationController.value = Matrix4.identity()
      ..translate(translateX, translateY)
      ..scale(scale);
  }

  Future<void> _pickPdf() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );

      if (result != null) {
        final platformFile = result.files.single;
        // Im Web sind bytes direkt verfügbar. Auf nativen Plattformen lesen wir vom Pfad.
        final Uint8List? bytes =
            platformFile.bytes ??
            (!kIsWeb && platformFile.path != null
                ? await File(platformFile.path!).readAsBytes()
                : null);

        if (bytes != null) {
          setState(() => _isLoading = true);

          await for (var page in Printing.raster(bytes, pages: [0], dpi: 300)) {
            final png = await page.toPng();
            setState(() {
              _pdfBytes = png;
              _pdfSize = Size(page.width.toDouble(), page.height.toDouble());
              _pdfPath = kIsWeb ? null : platformFile.path;
              _measurementPoints.clear();
              _isCalibrating = false;
              _showGrid = false;
              _snapToGrid = false;
              _gridSizeX = 2.0;
              _gridSizeY = 2.0;
              _gridOffset = Offset.zero;
              _isMovingGrid = false;
              _calibrationStart = null;
              _calibrationEnd = null;
              _currentMousePosition = null;
              _transformationController.value =
                  Matrix4.identity(); // Reset first
              // After setting PDF size and knowing viewport size, fit to screen
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _fitPdfToScreen();
              });
              _isLoading = false;
            });
            break;
          }
        }
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Fehler beim Laden der PDF: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showColorPicker() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Hintergrundfarbe wählen'),
          content: SingleChildScrollView(
            child: ColorPicker(
              pickerColor: context.read<ThemeProvider>().backgroundColor,
              onColorChanged: (color) {
                context.read<ThemeProvider>().setBackgroundColor(color);
              },
              pickerAreaHeightPercent: 0.8,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  void _showCalibrationDialog() {
    if (_calibrationStart == null || _calibrationEnd == null) return;

    final controller = TextEditingController(text: '5.0');
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Maßstab festlegen'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Länge in Meter'),
        ),
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                _isCalibrating = false;
                _calibrationStart = null;
                _calibrationEnd = null;
                _currentMousePosition = null;
              });
              Navigator.pop(context);
            },
            child: const Text('Abbrechen'),
          ),
          ElevatedButton(
            onPressed: () {
              final meters = double.tryParse(controller.text) ?? 5.0;
              final distance = (_calibrationEnd! - _calibrationStart!).distance;
              setState(() {
                _pixelsPerMeter = distance / meters;
                _isCalibrating = false;
                _calibrationStart = null;
                _calibrationEnd = null;
                _currentMousePosition = null;
              });
              Navigator.pop(context);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showProjectInfoDialog() {
    final pController = TextEditingController(text: _projectName);
    final sController = TextEditingController(text: _surveyorName);
    final dController = TextEditingController(text: _usedDevices);
    final nController = TextEditingController(text: _additionalNotes);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Projekt-Informationen'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: pController,
                decoration: const InputDecoration(labelText: 'Projektname'),
              ),
              TextField(
                controller: sController,
                decoration: const InputDecoration(labelText: 'Prüfer / Person'),
              ),
              TextField(
                controller: dController,
                decoration: const InputDecoration(
                  labelText: 'Verwendete Geräte',
                ),
              ),
              TextField(
                controller: nController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Zusätzliche Infos',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() {
                _projectName = pController.text;
                _surveyorName = sController.text;
                _usedDevices = dController.text;
                _additionalNotes = nController.text;
              });
              Navigator.pop(context);
            },
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
  }

  String _getFormattedDateTime() {
    final now = DateTime.now();
    return '${now.day.toString().padLeft(2, '0')}.${now.month.toString().padLeft(2, '0')}.${now.year} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  }

  void _editMarkerData(int index) {
    final marker = _measurementPoints[index];
    final labelController = TextEditingController(text: marker.label);
    final valueController = TextEditingController(
      text: marker.sensorValue?.toString() ?? '',
    );
    final heightController = TextEditingController(
      text: marker.height.toString(),
    );

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Marker ${index + 1} bearbeiten'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: labelController,
              decoration: const InputDecoration(
                labelText: 'Bezeichnung (z.B. Raumname)',
              ),
            ),
            TextField(
              controller: heightController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Messhöhe (m)',
                suffixText: 'm',
              ),
            ),
            TextField(
              controller: valueController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Sensorwert (Lux)'),
            ),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              onPressed: () {
                // Simulation eines Sensor-Events
                setState(() {
                  valueController.text = (Random().nextDouble() * 500 + 100)
                      .toStringAsFixed(1);
                });
              },
              icon: const Icon(Icons.bluetooth_connected),
              label: const Text('Sensorwert abfragen'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() {
                marker.label = labelController.text;
                marker.height = double.tryParse(heightController.text) ?? 0.8;
                marker.sensorValue = double.tryParse(valueController.text);
              });
              Navigator.pop(context);
            },
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportToPdf() async {
    if (_pdfBytes == null) return;

    final pdf = pw.Document();
    final image = pw.MemoryImage(_pdfBytes!);

    // Seite 1: Grundriss mit Overlays
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        orientation: _pdfSize!.width > _pdfSize!.height
            ? pw.PageOrientation.landscape
            : pw.PageOrientation.portrait,
        build: (pw.Context context) {
          return pw.FittedBox(
            fit: pw.BoxFit.contain,
            child: pw.SizedBox(
              width: _pdfSize!.width,
              height: _pdfSize!.height,
              child: pw.Stack(
                children: [
                  pw.Image(image),
                  ..._measurementPoints.map((marker) {
                    return pw.Positioned(
                      left: marker.position.dx - (_markerSize / 2),
                      top: marker.position.dy - _markerSize,
                      child: pw.Column(
                        mainAxisSize: pw.MainAxisSize.min,
                        children: [
                          pw.Text(
                            marker.label,
                            style: pw.TextStyle(
                              fontSize: _markerSize * 0.6,
                              color: PdfColors.red,
                              fontWeight: pw.FontWeight.bold,
                            ),
                          ),
                          if (marker.sensorValue != null)
                            pw.Text(
                              '${marker.sensorValue} lx',
                              style: pw.TextStyle(
                                fontSize: _markerSize * 0.5,
                                color: PdfColors.green,
                              ),
                            ),
                          pw.Container(
                            width: _markerSize * 0.5,
                            height: _markerSize * 0.5,
                            decoration: const pw.BoxDecoration(
                              color: PdfColors.red,
                              shape: pw.BoxShape.circle,
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
          );
        },
      ),
    );

    // Helper for PDF Stat Cards
    pw.Widget buildPdfStatCard(String title, String value, PdfColor color) {
      return pw.Container(
        width: 160,
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(
          color: color,
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
        ),
        child: pw.Column(
          children: [
            pw.Text(
              title,
              style: pw.TextStyle(color: PdfColors.white, fontSize: 10),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              value,
              style: pw.TextStyle(
                color: PdfColors.white,
                fontWeight: pw.FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ],
        ),
      );
    }

    // Seite 2: Tabellarische Auflistung
    final sensorValues = _measurementPoints
        .map((m) => m.sensorValue)
        .whereType<double>()
        .toList();

    final double? minVal = sensorValues.isEmpty
        ? null
        : sensorValues.reduce(min);
    final double? maxVal = sensorValues.isEmpty
        ? null
        : sensorValues.reduce(max);
    final double? meanVal = sensorValues.isEmpty
        ? null
        : sensorValues.reduce((a, b) => a + b) / sensorValues.length;

    pdf.addPage(
      pw.Page(
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                'Messbericht - Beleuchtungsstärken',
                style: pw.TextStyle(
                  fontSize: 24,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 20),

              // Projekt-Details Header
              pw.Container(
                padding: const pw.EdgeInsets.all(10),
                decoration: const pw.BoxDecoration(
                  color: PdfColors.grey100,
                  borderRadius: pw.BorderRadius.all(pw.Radius.circular(8)),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Text(
                          'Projekt: ${_projectName.isEmpty ? "Unbenannt" : _projectName}',
                          style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                        ),
                        pw.Text('Datum/Zeit: ${_getFormattedDateTime()}'),
                      ],
                    ),
                    pw.Divider(color: PdfColors.grey300),
                    pw.Text(
                      'Prüfer: ${_surveyorName.isEmpty ? "Nicht angegeben" : _surveyorName}',
                    ),
                    pw.Text(
                      'Geräte: ${_usedDevices.isEmpty ? "Nicht angegeben" : _usedDevices}',
                    ),
                    if (_additionalNotes.isNotEmpty)
                      pw.Padding(
                        padding: const pw.EdgeInsets.only(top: 4),
                        child: pw.Text(
                          'Notizen: $_additionalNotes',
                          style: pw.TextStyle(
                            fontStyle: pw.FontStyle.italic,
                            color: PdfColors.grey700,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              pw.SizedBox(height: 25),

              // Statistik Dashboard
              if (sensorValues.isNotEmpty)
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    buildPdfStatCard(
                      'Minimum (Emin)',
                      '${minVal!.toStringAsFixed(1)} lx',
                      PdfColors.blueGrey700,
                    ),
                    buildPdfStatCard(
                      'Mittelwert (Em)',
                      '${meanVal!.toStringAsFixed(1)} lx',
                      PdfColors.blue700,
                    ),
                    buildPdfStatCard(
                      'Maximum (Emax)',
                      '${maxVal!.toStringAsFixed(1)} lx',
                      PdfColors.teal700,
                    ),
                  ],
                ),
              pw.SizedBox(height: 30),

              pw.Table.fromTextArray(
                border: null,
                headerStyle: pw.TextStyle(
                  color: PdfColors.white,
                  fontWeight: pw.FontWeight.bold,
                ),
                headerDecoration: const pw.BoxDecoration(
                  color: PdfColors.blueGrey900,
                ),
                rowDecoration: const pw.BoxDecoration(
                  border: pw.Border(
                    bottom: pw.BorderSide(color: PdfColors.grey300, width: 0.5),
                  ),
                ),
                cellHeight: 30,
                cellAlignments: {
                  0: pw.Alignment.centerLeft,
                  1: pw.Alignment.centerLeft,
                  2: pw.Alignment.centerLeft,
                  3: pw.Alignment.centerLeft,
                  4: pw.Alignment.centerRight,
                },
                headers: ['#', 'Bezeichnung', 'Position (X/Y)', 'Höhe', 'Wert'],
                data: _measurementPoints.asMap().entries.map((e) {
                  final m = e.value;
                  final x = (m.position.dx / _pixelsPerMeter).toStringAsFixed(
                    2,
                  );
                  final y = (m.position.dy / _pixelsPerMeter).toStringAsFixed(
                    2,
                  );
                  return [
                    '${e.key + 1}',
                    m.label,
                    '${x}m / ${y}m',
                    '${m.height}m',
                    m.sensorValue != null ? '${m.sensorValue} lx' : '-',
                  ];
                }).toList(),
              ),
            ],
          );
        },
      ),
    );

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdf.save(),
    );
  }

  Offset _snapToGridOffset(Offset pos) {
    if (!_showGrid || !_snapToGrid) return pos;
    final double gx = _gridSizeX * _pixelsPerMeter;
    final double gy = _gridSizeY * _pixelsPerMeter;
    return Offset(
      ((pos.dx - _gridOffset.dx) / gx).round() * gx + _gridOffset.dx,
      ((pos.dy - _gridOffset.dy) / gy).round() * gy + _gridOffset.dy,
    );
  }

  Future<void> _saveProject() async {
    if (_pdfBytes == null) return;

    try {
      final Map<String, dynamic> projectData = {
        'projectName': _projectName,
        'surveyorName': _surveyorName,
        'usedDevices': _usedDevices,
        'additionalNotes': _additionalNotes,
        'pixelsPerMeter': _pixelsPerMeter,
        'gridSizeX': _gridSizeX,
        'gridSizeY': _gridSizeY,
        'gridOffsetX': _gridOffset.dx,
        'gridOffsetY': _gridOffset.dy,
        'snapToGrid': _snapToGrid,
        'markerSize': _markerSize,
        'pdfSizeWidth': _pdfSize?.width,
        'pdfSizeHeight': _pdfSize?.height,
        'pdfBytesBase64': base64Encode(_pdfBytes!),
        'markers': _measurementPoints.map((m) => m.toJson()).toList(),
      };

      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(projectData)));
      final success = await saveProjectFile(bytes, 'lichtmessung.lmp');

      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Projekt erfolgreich gespeichert')),
        );
      }
    } catch (e) {
      debugPrint('Save Error: $e');
    }
  }

  Future<void> _loadProject() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['lmp'],
      );

      if (result != null) {
        final platformFile = result.files.single;
        final String? content = platformFile.bytes != null
            ? utf8.decode(platformFile.bytes!)
            : (!kIsWeb && platformFile.path != null
                  ? await File(platformFile.path!).readAsString()
                  : null);

        if (content != null) {
          final data = jsonDecode(content);

          setState(() {
            _projectName = data['projectName'] ?? '';
            _surveyorName = data['surveyorName'] ?? '';
            _usedDevices = data['usedDevices'] ?? '';
            _additionalNotes = data['additionalNotes'] ?? '';
            _pixelsPerMeter = data['pixelsPerMeter'] ?? 100.0;
            _gridSizeX = data['gridSizeX'] ?? 2.0;
            _gridSizeY = data['gridSizeY'] ?? 2.0;
            _gridOffset = Offset(
              (data['gridOffsetX'] as num? ?? 0.0).toDouble(),
              (data['gridOffsetY'] as num? ?? 0.0).toDouble(),
            );
            _snapToGrid = data['snapToGrid'] ?? false;
            _markerSize = data['markerSize'] ?? 24.0;
            _pdfSize = Size(data['pdfSizeWidth'], data['pdfSizeHeight']);
            _pdfBytes = base64Decode(data['pdfBytesBase64']);
            _measurementPoints.clear();
            for (var m in data['markers']) {
              _measurementPoints.add(MeasurementMarker.fromJson(m));
            }
          });
        }
      }
    } catch (e) {
      debugPrint('Load Error: $e');
    }
  }

  void _cancelCalibration() {
    setState(() {
      _isCalibrating = false;
      _calibrationStart = null;
      _calibrationEnd = null;
      _currentMousePosition = null;
    });
  }

  Offset _transformOffset(Offset viewportOffset) {
    final matrix = _transformationController.value;
    final translation = matrix.getTranslation();
    final scale = matrix.getMaxScaleOnAxis();

    return Offset(
      (viewportOffset.dx - translation.x) / scale,
      (viewportOffset.dy - translation.y) / scale,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lightmeter Pro'),
        actions: [
          if (_isLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16.0),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
              ),
            ),
          IconButton(
            icon: Icon(
              Icons.straighten,
              color: _isCalibrating ? Colors.orange : null,
            ),
            onPressed: () {
              setState(() {
                _isCalibrating = !_isCalibrating;
                _calibrationStart = null; // Reset calibration points
                _calibrationEnd = null;
                _currentMousePosition = null;
              });
            },
            tooltip: 'Kalibrieren',
          ),
          if (_isCalibrating)
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: _cancelCalibration,
              tooltip: 'Kalibrierung abbrechen',
            ),
          IconButton(
            icon: const Icon(Icons.color_lens),
            onPressed: _showColorPicker,
            tooltip: 'Hintergrundfarbe',
          ),
          IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            onPressed: _pdfBytes != null ? _exportToPdf : null,
            tooltip: 'Export als PDF',
          ),
          IconButton(
            icon: const Icon(Icons.folder),
            onPressed: _pickPdf,
            tooltip: 'PDF öffnen',
          ),
          IconButton(
            icon: const Icon(Icons.brightness_6),
            onPressed: () => context.read<ThemeProvider>().toggleTheme(),
            tooltip: 'Theme umschalten',
          ),
        ],
      ),
      drawer: Drawer(
        child: ListView(
          children: [
            DrawerHeader(
              decoration: BoxDecoration(color: Theme.of(context).primaryColor),
              child: const Text(
                'Menü',
                style: TextStyle(color: Colors.white, fontSize: 24),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.file_open),
              title: const Text('Projekt laden'),
              onTap: () {
                Navigator.pop(context);
                _loadProject();
              },
            ),
            ListTile(
              leading: const Icon(Icons.save),
              title: const Text('Projekt speichern'),
              onTap: () {
                Navigator.pop(context);
                _saveProject();
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Projekt-Infos bearbeiten'),
              onTap: () {
                Navigator.pop(context);
                _showProjectInfoDialog();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete),
              title: const Text('Messpunkte löschen'),
              onTap: () {
                Navigator.pop(context);
                setState(() => _measurementPoints.clear());
              },
            ),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('Neustart'),
              onTap: () {
                Navigator.pop(context);
                _confirmReset();
              },
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 8.0,
              ),
              child: Text(
                'Hilfsraster',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.grid_4x4),
              title: const Text('Raster anzeigen'),
              value: _showGrid,
              onChanged: (val) => setState(() => _showGrid = val),
            ),
            if (_showGrid) ...[
              SwitchListTile(
                secondary: const Icon(Icons.pin_drop),
                title: const Text('Am Raster andocken'),
                value: _snapToGrid,
                onChanged: (val) => setState(() => _snapToGrid = val),
              ),
              ListTile(
                title: Text('X-Raster: ${_gridSizeX.toStringAsFixed(1)} m'),
                subtitle: Slider(
                  value: _gridSizeX,
                  min: 0.5,
                  max: 20.0,
                  divisions: 39,
                  onChanged: (val) => setState(() => _gridSizeX = val),
                ),
              ),
              ListTile(
                title: Text('Y-Raster: ${_gridSizeY.toStringAsFixed(1)} m'),
                subtitle: Slider(
                  value: _gridSizeY,
                  min: 0.5,
                  max: 20.0,
                  divisions: 39,
                  onChanged: (val) => setState(() => _gridSizeY = val),
                ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.open_with),
                title: const Text('Raster verschieben'),
                subtitle: const Text('Maus ziehen zum Bewegen'),
                value: _isMovingGrid,
                onChanged: (val) => setState(() => _isMovingGrid = val),
              ),
              ListTile(
                leading: const Icon(Icons.restore),
                title: const Text('Position zurücksetzen'),
                onTap: () {
                  setState(() {
                    _gridOffset = Offset.zero;
                  });
                },
              ),
            ],
            const Divider(),
            ListTile(
              leading: const Icon(Icons.straighten),
              title: const Text('Marker-Größe'),
              subtitle: Slider(
                value: _markerSize,
                min: 12,
                max: 500,
                onChanged: (val) => setState(() => _markerSize = val),
              ),
            ),
          ],
        ),
      ),
      body: _pdfBytes == null
          ? Center(
              child: ElevatedButton(
                onPressed: _pickPdf,
                child: const Text('PDF Grundriss laden'),
              ),
            )
          : LayoutBuilder(
              // New: Use LayoutBuilder to get the available size for the PDF
              builder: (context, constraints) {
                // Update _viewportSize whenever the layout changes
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_viewportSize != constraints.biggest) {
                    setState(() {
                      _viewportSize = constraints.biggest;
                      // Optionally refit the PDF if viewport changes significantly
                      // _fitPdfToScreen();
                    });
                  }
                });

                return InteractiveViewer(
                  transformationController: _transformationController,
                  constrained: false,
                  boundaryMargin: const EdgeInsets.all(double.infinity),
                  minScale: 0.1,
                  maxScale: 10.0,
                  child: SizedBox(
                    key: _pdfKey,
                    width: _pdfSize?.width,
                    height: _pdfSize?.height,
                    child: Stack(
                      children: [
                        // The actual PDF Image
                        Image.memory(
                          _pdfBytes!,
                          fit: BoxFit.none,
                          alignment: Alignment.topLeft,
                        ),
                        // Hilfsraster
                        if (_showGrid && _pdfSize != null)
                          Positioned.fill(
                            child: CustomPaint(
                              painter: GridPainter(
                                gridSizeX: _gridSizeX * _pixelsPerMeter,
                                gridSizeY: _gridSizeY * _pixelsPerMeter,
                                offset: _gridOffset,
                                pdfSize: _pdfSize!,
                                controller: _transformationController,
                              ),
                            ),
                          ),
                        // Interaction layer (Tap to add points)
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onPanUpdate: _isMovingGrid
                                ? (details) {
                                    final scale = _transformationController
                                        .value
                                        .getMaxScaleOnAxis();
                                    setState(
                                      () =>
                                          _gridOffset += details.delta / scale,
                                    );
                                  }
                                : null,
                            onTapUp: (TapUpDetails details) {
                              if (_isMovingGrid) return;
                              final position = _snapToGridOffset(
                                details.localPosition,
                              );
                              if (_isCalibrating) {
                                if (_calibrationStart == null) {
                                  setState(() => _calibrationStart = position);
                                } else if (_calibrationEnd == null) {
                                  setState(() => _calibrationEnd = position);
                                  _showCalibrationDialog();
                                }
                              } else {
                                setState(() {
                                  _measurementPoints.add(
                                    MeasurementMarker(
                                      position: position,
                                      height: 0.8,
                                      label:
                                          'Punkt ${_measurementPoints.length + 1}',
                                    ),
                                  );
                                });
                              }
                            },
                            child: MouseRegion(
                              onHover: (event) {
                                if (_isCalibrating) {
                                  setState(
                                    () => _currentMousePosition =
                                        event.localPosition,
                                  );
                                }
                              },
                              child: CustomPaint(
                                painter: MeasurementPainter(
                                  calibrationStart: _calibrationStart,
                                  calibrationEnd: _calibrationEnd,
                                  currentMousePosition: _currentMousePosition,
                                  isCalibrating: _isCalibrating,
                                  controller: _transformationController,
                                ),
                              ),
                            ),
                          ),
                        ),
                        // Measurement Markers
                        ..._measurementPoints.asMap().entries.map((entry) {
                          int index = entry.key;
                          MeasurementMarker marker = entry.value;
                          return Positioned(
                            left: marker.position.dx - (_markerSize / 2),
                            top: marker.position.dy - _markerSize,
                            child: GestureDetector(
                              onTap: () => _editMarkerData(index),
                              onPanStart: (details) {
                                final RenderBox box =
                                    _pdfKey.currentContext!.findRenderObject()
                                        as RenderBox;
                                final Offset localTouch = box.globalToLocal(
                                  details.globalPosition,
                                );
                                _dragPositionAccumulator =
                                    localTouch - marker.position;
                              },
                              onPanUpdate: (details) {
                                final RenderBox box =
                                    _pdfKey.currentContext!.findRenderObject()
                                        as RenderBox;
                                final Offset localTouch = box.globalToLocal(
                                  details.globalPosition,
                                );
                                setState(() {
                                  final newPos =
                                      localTouch - _dragPositionAccumulator;
                                  _measurementPoints[index].position =
                                      _snapToGridOffset(newPos);
                                });
                              },
                              onSecondaryTap: () {
                                setState(() {
                                  _measurementPoints.removeAt(index);
                                });
                              },
                              child: Column(
                                children: [
                                  Text(
                                    marker.label.isNotEmpty
                                        ? marker.label
                                        : '${index + 1}',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: _markerSize * 0.6,
                                      shadows: const [
                                        Shadow(
                                          blurRadius: 2.0,
                                          color: Colors.black,
                                          offset: Offset(1.0, 1.0),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (marker.sensorValue != null)
                                    Container(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: _markerSize * 0.15,
                                        vertical: _markerSize * 0.08,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.black54,
                                        borderRadius: BorderRadius.circular(
                                          _markerSize * 0.15,
                                        ),
                                      ),
                                      child: Text(
                                        '${marker.sensorValue} lx',
                                        style: TextStyle(
                                          color: Colors.greenAccent,
                                          fontSize: _markerSize * 0.5,
                                        ),
                                      ),
                                    ),
                                  Icon(
                                    Icons.location_on,
                                    color: Colors.red,
                                    size: _markerSize,
                                  ),
                                ],
                              ),
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                );
              },
            ),
      bottomSheet: _measurementPoints.isNotEmpty
          ? Container(
              height: 120,
              color: Theme.of(context).cardColor,
              child: ListView.builder(
                itemCount: _measurementPoints.length,
                itemBuilder: (context, index) {
                  final marker = _measurementPoints[index];
                  double realX = marker.position.dx / _pixelsPerMeter;
                  double realY = marker.position.dy / _pixelsPerMeter;
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Theme.of(context).primaryColor,
                      child: Text(
                        '${index + 1}',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    title: Text('${marker.label} (h: ${marker.height}m)'),
                    subtitle: Text(
                      'Pos: ${realX.toStringAsFixed(2)}m / ${realY.toStringAsFixed(2)}m ${marker.sensorValue != null ? "| Wert: ${marker.sensorValue} Lux" : ""}',
                    ),
                    onTap: () => _editMarkerData(index),
                  );
                },
              ),
            )
          : null,
    );
  }
}

class GridPainter extends CustomPainter {
  final double gridSizeX;
  final double gridSizeY;
  final Offset offset;
  final Size pdfSize;
  final TransformationController controller;

  GridPainter({
    required this.gridSizeX,
    required this.gridSizeY,
    required this.offset,
    required this.pdfSize,
    required this.controller,
  }) : super(repaint: controller);

  @override
  void paint(Canvas canvas, Size size) {
    final scale = controller.value.getMaxScaleOnAxis();
    final paint = Paint()
      ..color = Colors.green.withOpacity(0.5)
      ..strokeWidth = 1.2 / scale;

    // Vertikale Linien
    double startX = gridSizeX > 0 ? (offset.dx % gridSizeX) : 0;
    if (startX > 0) startX -= gridSizeX;
    for (double x = startX; x <= pdfSize.width; x += gridSizeX) {
      canvas.drawLine(Offset(x, 0), Offset(x, pdfSize.height), paint);
    }

    // Horizontale Linien
    double startY = gridSizeY > 0 ? (offset.dy % gridSizeY) : 0;
    if (startY > 0) startY -= gridSizeY;
    for (double y = startY; y <= pdfSize.height; y += gridSizeY) {
      canvas.drawLine(Offset(0, y), Offset(pdfSize.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(GridPainter oldDelegate) =>
      oldDelegate.gridSizeX != gridSizeX ||
      oldDelegate.gridSizeY != gridSizeY ||
      oldDelegate.offset != offset ||
      oldDelegate.pdfSize != pdfSize ||
      oldDelegate.controller != controller;
}

class MeasurementPainter extends CustomPainter {
  final Offset? calibrationStart;
  final Offset? calibrationEnd;
  final Offset? currentMousePosition;
  final bool isCalibrating;
  final TransformationController controller;

  MeasurementPainter({
    this.calibrationStart,
    this.calibrationEnd,
    this.currentMousePosition,
    required this.isCalibrating,
    required this.controller,
  }) : super(repaint: controller);

  @override
  void paint(Canvas canvas, Size size) {
    if (!isCalibrating) return; // Only paint during calibration

    final scale = controller.value.getMaxScaleOnAxis();

    if (calibrationStart != null) {
      final paint = Paint()
        ..color = Colors.orange
        ..strokeWidth = 3 / scale
        ..style = PaintingStyle.stroke;

      final start = calibrationStart!;
      final end = calibrationEnd ?? currentMousePosition ?? start;

      // Zeichne Gummiband-Linie
      canvas.drawLine(start, end, paint);

      // Zeichne Start- und Endpunkte
      paint.style = PaintingStyle.fill;
      canvas.drawCircle(start, 6 / scale, paint);
      canvas.drawCircle(end, 6 / scale, paint);
    }
  }

  @override
  bool shouldRepaint(covariant MeasurementPainter oldDelegate) =>
      calibrationStart != oldDelegate.calibrationStart ||
      calibrationEnd != oldDelegate.calibrationEnd ||
      currentMousePosition != oldDelegate.currentMousePosition ||
      isCalibrating != oldDelegate.isCalibrating ||
      controller != oldDelegate.controller;
}
