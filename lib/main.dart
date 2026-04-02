import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:light_sensor/light_sensor.dart';
import 'dart:async';
import 'package:flutter_web_bluetooth/flutter_web_bluetooth.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:printing/printing.dart'; // Für stabiles PDF-Rendering
import 'package:url_launcher/url_launcher.dart';
import 'save_helper.dart' if (dart.library.html) 'save_helper_web.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'widgets/bluetooth_service.dart';
import 'models/measurement_models.dart';
import 'providers/theme_provider.dart';
import 'widgets/custom_painters.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: const LightmeterApp(),
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
  bool _isLoading = false;
  Uint8List? _pdfBytes;
  Size? _pdfSize;
  Size?
  _viewportSize; // New: To store the size of the InteractiveViewer's parent

  final GlobalKey _pdfKey = GlobalKey();
  // Project Information
  String _projectName = '';
  String _surveyorName = '';
  String _projectDate = '';
  String _usedDevices = '';
  String _additionalNotes = '';
  bool _showSensorSheet = false;

  bool _hasHardwareSensor = false;
  StreamSubscription? _lightSubscription;
  BluetoothDevice? _btDevice;
  bool _isBluetoothConnecting = false;

  // Aktuelle Sensorwerte
  double? _currentDistanceValue;
  DateTime _lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _projectDate = _getFormattedDateTime();
    _initLightSensor();
  }

  @override
  void dispose() {
    _lightSubscription?.cancel();
    _btDevice?.disconnect();
    super.dispose();
  }

  Future<void> _initLightSensor() async {
    _lightSubscription?.cancel();

    // Das Plugin 'light_sensor' unterstützt nur Android nativ.
    final bool isNativeAndroid = !kIsWeb && Platform.isAndroid;

    if (isNativeAndroid) {
      try {
        bool hasSensor = await LightSensor.hasSensor();
        if (hasSensor) {
          setState(() => _hasHardwareSensor = true);
          _lightSubscription = LightSensor.luxStream().listen(
            (lux) {
              if (mounted) {
                setState(() => _currentLightValue = lux.toDouble());
              }
            },
            onError: (e) {
              debugPrint('Sensor Stream Fehler: $e');
              _startSimulation();
            },
          );
          return; // Erfolgreich gestartet
        }
      } catch (e) {
        debugPrint('Fehler beim Sensor-Check: $e');
      }
    }

    // Fallback zu Simulation (Web, iOS, Emulator oder kein Sensor)
    _startSimulation();
  }

  void _startSimulation() {
    _lightSubscription?.cancel();
    setState(() => _hasHardwareSensor = false);
    _lightSubscription =
        Stream.periodic(const Duration(milliseconds: 1500), (count) {
          return 250.0 + (Random().nextDouble() * 20 - 10);
        }).listen((simulatedValue) {
          if (mounted) {
            setState(() => _currentLightValue = simulatedValue);
          }
        });
  }

  Future<void> _connectExternalSensor() async {
    if (!kIsWeb) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Bluetooth-Sensoren werden aktuell nur in der Web-Version unterstützt.',
            ),
          ),
        );
      }
      return;
    }

    final bool bluetoothAvailable =
        await FlutterWebBluetooth.instance.isAvailable.first;
    if (!bluetoothAvailable) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Web Bluetooth ist in diesem Browser nicht verfügbar oder deaktiviert.',
            ),
          ),
        );
      }
      return;
    }

    setState(() => _isBluetoothConnecting = true);
    try {
      final device = await AppBluetoothService.requestDevice();

      await device.connect();
      setState(() => _btDevice = device);

      // FIX: Breche die Simulation oder den internen Sensor-Stream ab,
      // damit die Werte nicht mit den Bluetooth-Daten kollidieren.
      await _lightSubscription?.cancel();
      _lightSubscription = null;

      final characteristicFound = await AppBluetoothService.discoverAndListen(
        device,
        _handleBluetoothData,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              characteristicFound
                  ? 'Verbunden mit "${device.name ?? 'Unbekannt'}"'
                  : 'Verbunden, aber keine passende Daten-Charakteristik gefunden.',
            ),
            backgroundColor: characteristicFound ? Colors.green : Colors.orange,
          ),
        );
      }
    } catch (e) {
      debugPrint('Bluetooth Fehler: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Verbindung fehlgeschlagen: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isBluetoothConnecting = false);
    }
  }

  void _handleBluetoothData(String uuid, ByteData data) {
    try {
      bool updated = false;

      // Parsing basierend auf der UUID (wie im HTML Script)
      if (uuid == AppBluetoothService.luxCharUuid && data.lengthInBytes >= 4) {
        _currentLightValue = data.getFloat32(0, Endian.little);
        updated = true;
      } else if (uuid == AppBluetoothService.distCharUuid &&
          data.lengthInBytes >= 2) {
        _currentDistanceValue = data.getUint16(0, Endian.little).toDouble();
        updated = true;
      }

      if (updated && mounted) {
        final now = DateTime.now();
        // Drosselung auf max 10 Updates pro Sekunde
        if (now.difference(_lastUiUpdate).inMilliseconds > 100) {
          setState(() {
            _hasHardwareSensor = true;
          });
          _lastUiUpdate = now;
        }
      }
    } catch (e) {
      debugPrint('Fehler beim Parsen der Bluetooth-Daten: $e');
    }
  }

  // Grid Settings
  bool _showGrid = false;
  bool _snapToGrid = false;
  double _gridSizeX = 2.0;
  double _gridSizeY = 2.0;
  Offset _gridOffset = Offset.zero;
  bool _isMovingGrid = false;

  final List<MeasurementArea> _areas = [MeasurementArea(name: 'Allgemein')];
  int _selectedAreaIndex = 0;

  List<MeasurementMarker> get _currentPoints =>
      _areas[_selectedAreaIndex].markers;

  bool _isCalibrating = false;
  Offset? _calibrationStart;
  Offset? _calibrationEnd;
  Offset? _currentMousePosition;
  double _pixelsPerMeter = 100.0;
  Uint8List? _logoBytes;
  bool _isExportingPdf = false; // New state variable for PDF export progress
  bool _isSettingReferencePoint = false;
  Offset _referencePoint = Offset.zero;
  double _markerSize = 24.0;
  Offset _dragPositionAccumulator = Offset.zero;
  final TransformationController _transformationController =
      TransformationController();

  // Sensor-bezogene Variablen
  double? _currentLightValue;
  double _lightCalibrationFactor = 1.0;

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
        _pdfBytes = null;
        _logoBytes = null;
        _pdfSize = null;
        _areas.clear();
        _areas.add(MeasurementArea(name: 'Allgemein'));
        _selectedAreaIndex = 0;
        _referencePoint = Offset.zero;
        _isSettingReferencePoint = false;
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
        _projectDate = _getFormattedDateTime();
        _usedDevices = '';
        _additionalNotes = '';
        _pixelsPerMeter = 100.0;
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
            print(
              'PDF Page rendered: ${page.width}x${page.height}, bytes: ${png.length}',
            );
            setState(() {
              _pdfBytes = png;
              _pdfSize = Size(page.width.toDouble(), page.height.toDouble());
              _areas.clear();
              _areas.add(MeasurementArea(name: 'Allgemein'));
              _selectedAreaIndex = 0;
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
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _pickLogo() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.image);
      if (result != null) {
        final platformFile = result.files.single;
        final Uint8List? bytes =
            platformFile.bytes ??
            (!kIsWeb && platformFile.path != null
                ? await File(platformFile.path!).readAsBytes()
                : null);

        setState(() {
          _logoBytes = bytes;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Logo-Fehler: $e')));
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
        title: const Text('Maßstab festlegen (Sensor)'),
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
    final dateController = TextEditingController(text: _projectDate);
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
                controller: dateController,
                decoration: const InputDecoration(labelText: 'Datum / Uhrzeit'),
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
                _projectDate = dateController.text;
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

  void _showAddAreaDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Neuer Bereich / Raum'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Name des Bereichs'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          ElevatedButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                setState(() {
                  _areas.add(MeasurementArea(name: controller.text));
                  _selectedAreaIndex = _areas.length - 1;
                });
              }
              Navigator.pop(context);
            },
            child: const Text('Erstellen'),
          ),
        ],
      ),
    );
  }

  void _showRenameAreaDialog(int index) {
    final controller = TextEditingController(text: _areas[index].name);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Bereich umbenennen'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Neuer Name'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          ElevatedButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                setState(() {
                  _areas[index].name = controller.text;
                });
              }
              Navigator.pop(context);
            },
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
  }

  void _editMarkerData(int index) {
    final marker = _currentPoints[index];
    final labelController = TextEditingController(text: marker.label);
    final valueController = TextEditingController(
      text: marker.sensorValue?.toString() ?? '',
    );
    final calibratedLightValue = _currentLightValue != null
        ? _currentLightValue! * _lightCalibrationFactor
        : null;
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
              controller: valueController, // Keep this for manual input
              keyboardType: TextInputType.number, // Allow manual input
              decoration: InputDecoration(labelText: 'Sensorwert (Lux)'),
            ),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              onPressed: () {
                if (calibratedLightValue != null) {
                  setState(() {
                    valueController.text = calibratedLightValue.toStringAsFixed(
                      1,
                    );
                  });
                } else {
                  // Fallback Simulation falls kein Sensor vorhanden (z.B. Emulator/Web)
                  setState(() {
                    valueController.text = (Random().nextDouble() * 500 + 100)
                        .toStringAsFixed(1);
                  });
                }
              },
              icon: calibratedLightValue != null
                  ? const Icon(Icons.sensors, color: Colors.green)
                  : const Icon(Icons.sensors_off),
              label: Text(
                calibratedLightValue != null
                    ? 'Sensorwert übernehmen (${calibratedLightValue.toStringAsFixed(1)} lx)'
                    : 'Sensor simulieren',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _currentPoints.removeAt(index);
              });
              Navigator.pop(context);
            },
            child: const Text(
              'Marker löschen',
              style: TextStyle(color: Colors.red),
            ),
          ),
          if (_areas.length > 1)
            TextButton(
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Bereich löschen?'),
                    content: Text(
                      'Soll der Bereich "${_areas[_selectedAreaIndex].name}" inklusive aller Punkte gelöscht werden?',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Nein'),
                      ),
                      ElevatedButton(
                        onPressed: () {
                          setState(() {
                            // Delete area
                            _areas.removeAt(_selectedAreaIndex);
                            _selectedAreaIndex = 0;
                          });
                          Navigator.pop(ctx);
                          Navigator.pop(context);
                        },
                        child: const Text('Ja, löschen'),
                      ),
                    ],
                  ),
                );
              },
              child: const Text(
                'Bereich löschen',
                style: TextStyle(color: Colors.red),
              ),
            ),
          ElevatedButton(
            onPressed: () {
              setState(() {
                marker.label = labelController.text; // Update label
                marker.sensorValue = double.tryParse(
                  valueController.text,
                ); // Update sensor value
                marker.height =
                    double.tryParse(heightController.text) ??
                    0.8; // Update height
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

    // Check if we have any points at all
    bool hasAnyPoints = _areas.any((area) => area.markers.isNotEmpty);
    if (!hasAnyPoints) return;

    setState(() => _isExportingPdf = true);
    // Kurze Verzögerung, damit das UI Zeit hat, den Ladekreis zu zeichnen
    await Future.delayed(const Duration(milliseconds: 100));

    try {
      final pdf = pw.Document();
      final image = pw.MemoryImage(_pdfBytes!);
      final pw.MemoryImage? logoImage = _logoBytes != null
          ? pw.MemoryImage(_logoBytes!)
          : null;

      pw.Widget buildPdfHeader() {
        return pw.Container(
          margin: const pw.EdgeInsets.only(bottom: 10),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              if (logoImage != null)
                pw.Container(height: 40, child: pw.Image(logoImage))
              else
                pw.Text(
                  'By OvW',
                  style: pw.TextStyle(fontSize: 12, color: PdfColors.grey),
                ),
              pw.Text(
                'Lightmeter Pro Report',
                style: pw.TextStyle(fontSize: 10, color: PdfColors.grey),
              ),
            ],
          ),
        );
      }

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
                    // Referenzpunkt (Nullpunkt) auf dem Plan einzeichnen
                    if (_referencePoint != Offset.zero)
                      pw.Positioned(
                        left: _referencePoint.dx - (_markerSize / 2),
                        top: _referencePoint.dy - (_markerSize / 2),
                        child: pw.SizedBox(
                          width: _markerSize,
                          height: _markerSize,
                          child: pw.Stack(
                            children: [
                              pw.Center(
                                child: pw.Container(
                                  width: _markerSize,
                                  height: 2,
                                  color: PdfColors.blue,
                                ),
                              ),
                              pw.Center(
                                child: pw.Container(
                                  width: 2,
                                  height: _markerSize,
                                  color: PdfColors.blue,
                                ),
                              ),
                              pw.Positioned(
                                left: _markerSize * 0.6,
                                top: _markerSize * 0.6,
                                child: pw.Text(
                                  'REF',
                                  style: pw.TextStyle(
                                    color: PdfColors.blue,
                                    fontWeight: pw.FontWeight.bold,
                                    fontSize: _markerSize * 0.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    // Alle Marker zeichnen
                    ..._areas
                        .map((area) {
                          return area.markers.asMap().entries.map((entry) {
                            final int markerIndex = entry.key;
                            final MeasurementMarker marker = entry.value;
                            return pw.Positioned(
                              left: marker.position.dx - (_markerSize / 2),
                              top: marker.position.dy - _markerSize,
                              child: pw.Column(
                                mainAxisSize: pw.MainAxisSize.min,
                                children: [
                                  pw.Text(
                                    area.name,
                                    style: pw.TextStyle(
                                      fontSize: _markerSize * 0.3,
                                      color: PdfColors.grey700,
                                    ),
                                  ),
                                  pw.Text(
                                    marker.label.isNotEmpty
                                        ? marker.label
                                        : '${markerIndex + 1}',
                                    style: pw.TextStyle(
                                      fontSize: _markerSize * 0.5,
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
                          }).toList();
                        })
                        .expand((element) => element),
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

      // Add Pages per Area
      for (var area in _areas) {
        if (area.markers.isEmpty) continue;

        final sensorValues = area.markers
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
          pw.MultiPage(
            build: (pw.Context context) {
              return [
                buildPdfHeader(),
                pw.Text(
                  'Messbericht - Bereich: ${area.name}',
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
                          pw.Text('Datum/Zeit: $_projectDate'),
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
                      bottom: pw.BorderSide(
                        color: PdfColors.grey300,
                        width: 0.5,
                      ),
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
                  headers: [
                    '#',
                    'Bezeichnung',
                    'Position (X/Y)',
                    'Höhe',
                    'Wert',
                  ],
                  data: area.markers.asMap().entries.map((e) {
                    final m = e.value;
                    final x =
                        ((m.position.dx - _referencePoint.dx) / _pixelsPerMeter)
                            .toStringAsFixed(2);
                    final y =
                        ((_referencePoint.dy - m.position.dy) / _pixelsPerMeter)
                            .toStringAsFixed(2);
                    return [
                      '${e.key + 1}',
                      m.label,
                      '${x}m / ${y}m',
                      '${m.height}m',
                      m.sensorValue != null ? '${m.sensorValue} lx' : '-',
                    ];
                  }).toList(),
                ),
              ];
            },
          ),
        );
      }
      await Printing.layoutPdf(
        onLayout: (PdfPageFormat format) async => pdf.save(),
      );
    } catch (e) {
      debugPrint('Export Error: $e');
    } finally {
      setState(() => _isExportingPdf = false);
    }
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
        'projectDate': _projectDate,
        'usedDevices': _usedDevices,
        'additionalNotes': _additionalNotes,
        'pixelsPerMeter': _pixelsPerMeter,
        'gridSizeX': _gridSizeX,
        'gridSizeY': _gridSizeY,
        'gridOffsetX': _gridOffset.dx,
        'gridOffsetY': _gridOffset.dy,
        'snapToGrid': _snapToGrid,
        'markerSize': _markerSize,
        'lightCalibrationFactor': _lightCalibrationFactor,
        'currentLightValue': _currentLightValue,
        'refPointX': _referencePoint.dx,
        'refPointY': _referencePoint.dy,
        'pdfSizeWidth': _pdfSize?.width,
        'pdfSizeHeight': _pdfSize?.height,
        'pdfBytesBase64': base64Encode(_pdfBytes!),
        'logoBytesBase64': _logoBytes != null
            ? base64Encode(_logoBytes!)
            : null,
        'areas': _areas.map((a) => a.toJson()).toList(),
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
            _projectDate = data['projectDate'] ?? _getFormattedDateTime();
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
            _lightCalibrationFactor = data['lightCalibrationFactor'] ?? 1.0;
            _currentLightValue = data['currentLightValue'];
            _markerSize = data['markerSize'] ?? 24.0;
            _logoBytes = data['logoBytesBase64'] != null
                ? base64Decode(data['logoBytesBase64'])
                : null;
            _referencePoint = Offset(
              (data['refPointX'] as num? ?? 0.0).toDouble(),
              (data['refPointY'] as num? ?? 0.0).toDouble(),
            );
            _pdfSize = Size(data['pdfSizeWidth'], data['pdfSizeHeight']);
            _pdfBytes = base64Decode(data['pdfBytesBase64']);
            _areas.clear();
            if (data['areas'] != null) {
              for (var a in data['areas']) {
                _areas.add(MeasurementArea.fromJson(a));
              }
            }
            _selectedAreaIndex = 0;
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
      _isSettingReferencePoint = false;
      _calibrationStart = null;
      _calibrationEnd = null;
      _currentMousePosition = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lightmeter Pro'),
        actions: [
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
          IconButton(
            icon: Icon(
              Icons.api,
              color: _isSettingReferencePoint ? Colors.blue : null,
            ),
            onPressed: () {
              setState(() {
                _isSettingReferencePoint = !_isSettingReferencePoint;
                _isCalibrating = false;
                if (_isSettingReferencePoint) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Klicken Sie auf den gewünschten Nullpunkt (z.B. unten links).',
                      ),
                    ),
                  );
                }
              });
            },
            tooltip: 'Referenzpunkt setzen',
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
          IconButton(
            icon: const Icon(Icons.lightbulb_outline),
            onPressed: () =>
                setState(() => _showSensorSheet = !_showSensorSheet),
            tooltip: 'Sensorwerte anzeigen',
          ),
          IconButton(
            icon: const Icon(Icons.volunteer_activism, color: Colors.redAccent),
            onPressed: () async {
              final Uri url = Uri.parse(
                'https://www.paypal.com/donate/?hosted_button_id=6S6AF2MLFZTEA',
              );
              if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Konnte PayPal Link nicht öffnen'),
                    ),
                  );
                }
              }
            },
            tooltip: 'Spenden via PayPal',
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
              subtitle: const Text('Gespeichertes Projekt öffnen'),
              onTap: () {
                Navigator.pop(context);
                _loadProject();
              },
            ),
            ListTile(
              leading: const Icon(Icons.add_photo_alternate),
              title: const Text('Logo hochladen'),
              trailing: _logoBytes != null
                  ? Image.memory(_logoBytes!, height: 30)
                  : const Text(
                      'By OvW',
                      style: TextStyle(color: Colors.grey, fontSize: 10),
                    ),
              subtitle: const Text('Erscheint im PDF-Kopf'),
              onTap: () {
                Navigator.pop(context);
                _pickLogo();
              },
            ),
            ListTile(
              leading: const Icon(Icons.save),
              title: const Text('Projekt speichern'),
              subtitle: const Text('Aktuellen Stand sichern'),
              onTap: () {
                Navigator.pop(context);
                _saveProject();
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Projekt-Infos bearbeiten'),
              subtitle: const Text('Name, Messgerät, Notizen'),
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
                setState(() => _currentPoints.clear());
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
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Info'),
              onTap: () {
                Navigator.pop(context);
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Info'),
                    content: const Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Lightmeter Pro',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                        ),
                        SizedBox(height: 8),
                        Text('Made by OvW'),
                        Text('Version: 0.5'),
                      ],
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Schließen'),
                      ),
                    ],
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.sensors),
              title: const Text('Sensorkalibrierung'),
              onTap: () {
                Navigator.pop(context);
                setState(() => _showSensorSheet = true);
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
              ListTile(
                leading: const Icon(Icons.gps_fixed),
                title: const Text('Referenzpunkt zurücksetzen'),
                onTap: () {
                  setState(() => _referencePoint = Offset.zero);
                  Navigator.pop(context);
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
      body: Column(
        children: [
          if (_pdfBytes != null)
            Container(
              height: 50,
              color: Theme.of(context).primaryColor.withValues(alpha: 0.1),
              child: Row(
                children: [
                  const Padding(
                    padding: EdgeInsets.only(left: 16, right: 8),
                    child: Text(
                      'Bereiche :',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: _areas.length,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      itemBuilder: (context, index) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: GestureDetector(
                            onLongPress: () => _showRenameAreaDialog(index),
                            child: ChoiceChip(
                              label: Text(_areas[index].name),
                              selected: _selectedAreaIndex == index,
                              onSelected: (selected) {
                                if (selected) {
                                  setState(() => _selectedAreaIndex = index);
                                }
                              },
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: _showAddAreaDialog,
                    tooltip: 'Neuen Bereich anlegen',
                  ),
                ],
              ),
            ),
          Expanded(
            child: Stack(
              children: [
                if (_pdfBytes == null)
                  Center(
                    child: ElevatedButton(
                      onPressed: _pickPdf,
                      child: const Text('PDF Grundriss laden'),
                    ),
                  )
                else
                  LayoutBuilder(
                    // New: Use LayoutBuilder to get the available size for the PDF
                    builder: (context, constraints) {
                      // Update _viewportSize whenever the layout changes
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (_viewportSize != constraints.biggest) {
                          setState(() {
                            _viewportSize =
                                constraints.biggest; // Update viewport size
                            _fitPdfToScreen(); // Refit PDF to new viewport size
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
                                fit: BoxFit.contain,
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
                                          final scale =
                                              _transformationController.value
                                                  .getMaxScaleOnAxis();
                                          setState(
                                            () => _gridOffset +=
                                                details.delta / scale,
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
                                        setState(
                                          () => _calibrationStart = position,
                                        );
                                      } else if (_calibrationEnd == null) {
                                        setState(
                                          () => _calibrationEnd = position,
                                        );
                                        _showCalibrationDialog();
                                      }
                                    } else if (_isSettingReferencePoint) {
                                      setState(() {
                                        _referencePoint = position;
                                        _isSettingReferencePoint = false;
                                      });
                                    } else {
                                      setState(() {
                                        _currentPoints.add(
                                          MeasurementMarker(
                                            position: position,
                                            height: 0.8,
                                            label:
                                                'P${_currentPoints.length + 1}',
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
                                        currentMousePosition:
                                            _currentMousePosition,
                                        isCalibrating: _isCalibrating,
                                        referencePoint: _referencePoint,
                                        isSettingReferencePoint:
                                            _isSettingReferencePoint,
                                        controller: _transformationController,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              // Measurement Markers
                              ..._currentPoints.asMap().entries.map((entry) {
                                int index = entry.key;
                                MeasurementMarker marker = entry.value;
                                return Positioned(
                                  left: marker.position.dx - (_markerSize / 2),
                                  top: marker.position.dy - _markerSize,
                                  child: GestureDetector(
                                    onTap: () => _editMarkerData(index),
                                    onPanStart: (details) {
                                      final RenderBox box =
                                          _pdfKey.currentContext!
                                                  .findRenderObject()
                                              as RenderBox;
                                      final Offset localTouch = box
                                          .globalToLocal(
                                            details.globalPosition,
                                          );
                                      _dragPositionAccumulator =
                                          localTouch - marker.position;
                                    },
                                    onPanUpdate: (details) {
                                      final RenderBox box =
                                          _pdfKey.currentContext!
                                                  .findRenderObject()
                                              as RenderBox;
                                      final Offset localTouch = box
                                          .globalToLocal(
                                            details.globalPosition,
                                          );
                                      setState(() {
                                        final newPos =
                                            localTouch -
                                            _dragPositionAccumulator;
                                        _currentPoints[index].position =
                                            _snapToGridOffset(newPos);
                                      });
                                    },
                                    onSecondaryTap: () {
                                      setState(() {
                                        _currentPoints.removeAt(index);
                                      });
                                    },
                                    child: Column(
                                      children: [
                                        Text(
                                          _areas[_selectedAreaIndex].name,
                                          style: TextStyle(
                                            color: Colors.white70,
                                            fontSize: _markerSize * 0.3,
                                            shadows: const [
                                              Shadow(
                                                blurRadius: 2.0,
                                                color: Colors.black,
                                                offset: Offset(1.0, 1.0),
                                              ),
                                            ],
                                          ),
                                        ),
                                        Text(
                                          marker.label.isNotEmpty
                                              ? marker.label
                                              : '${index + 1}',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: _markerSize * 0.5,
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
                                              borderRadius:
                                                  BorderRadius.circular(
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
                if (_isLoading || _isExportingPdf)
                  Container(
                    color: Colors.black26,
                    child: const Center(child: CircularProgressIndicator()),
                  ),
              ],
            ),
          ),
        ],
      ),
      bottomSheet: _showSensorSheet
          ? Container(
              height: 200,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 10,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Sensorkalibrierung',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      // Status-Anzeige für den Sensor
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: _hasHardwareSensor
                              ? Colors.green.withOpacity(0.1)
                              : Colors.orange.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _hasHardwareSensor
                                ? Colors.green
                                : Colors.orange,
                            width: 1,
                          ),
                        ),
                        child: Text(
                          _hasHardwareSensor
                              ? 'Hardware-Sensor aktiv'
                              : 'Simulations-Modus',
                          style: TextStyle(
                            color: _hasHardwareSensor
                                ? Colors.green
                                : Colors.orange,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      if (kIsWeb)
                        IconButton(
                          icon: Icon(
                            _btDevice != null
                                ? Icons.bluetooth_connected
                                : Icons.bluetooth,
                            color: _btDevice != null ? Colors.blue : null,
                          ),
                          onPressed: _isBluetoothConnecting
                              ? null
                              : _connectExternalSensor,
                          tooltip: 'Externen Bluetooth-Sensor verbinden',
                        ),
                      if (!_hasHardwareSensor && !kIsWeb && Platform.isAndroid)
                        IconButton(
                          icon: const Icon(Icons.refresh, size: 20),
                          tooltip: 'Sensor erneut suchen',
                          onPressed: _initLightSensor,
                        ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () =>
                            setState(() => _showSensorSheet = false),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Icon(Icons.lightbulb, color: Colors.orange),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _hasHardwareSensor && _currentLightValue == null
                              ? 'Warte auf Sensordaten...'
                              : 'Aktueller Wert: ${_currentLightValue?.toStringAsFixed(1) ?? "---"} lx',
                          style: const TextStyle(fontSize: 16),
                        ),
                      ),
                      Text(
                        _currentDistanceValue != null
                            ? 'Distanz: ${_currentDistanceValue!.toStringAsFixed(0)} cm'
                            : '',
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        'Kalibriert: ${(_currentLightValue != null ? (_currentLightValue! * _lightCalibrationFactor) : 0.0).toStringAsFixed(1)} lx',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.green,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Text('Faktor: '),
                      Expanded(
                        child: Slider(
                          value: _lightCalibrationFactor,
                          min: 0.1,
                          max: 5.0,
                          divisions: 49,
                          label: _lightCalibrationFactor.toStringAsFixed(2),
                          onChanged: (val) =>
                              setState(() => _lightCalibrationFactor = val),
                        ),
                      ),
                      Text(_lightCalibrationFactor.toStringAsFixed(2)),
                    ],
                  ),
                ],
              ),
            )
          : (_currentPoints.isNotEmpty
                ? Container(
                    height: 120,
                    color: Theme.of(context).cardColor,
                    child: ListView.builder(
                      itemCount: _currentPoints.length,
                      itemBuilder: (context, index) {
                        final marker = _currentPoints[index];
                        double realX =
                            (marker.position.dx - _referencePoint.dx) /
                            _pixelsPerMeter;
                        double realY =
                            (_referencePoint.dy - marker.position.dy) /
                            _pixelsPerMeter;
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Theme.of(context).primaryColor,
                            child: Text(
                              '${index + 1}',
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                          title: Text(
                            '${_areas[_selectedAreaIndex].name} - ${marker.label.isNotEmpty ? marker.label : index + 1} (h: ${marker.height}m)',
                          ),
                          subtitle: Text(
                            'Pos: ${realX.toStringAsFixed(2)}m / ${realY.toStringAsFixed(2)}m ${marker.sensorValue != null ? "| Wert: ${marker.sensorValue} Lux" : ""}',
                          ),
                          onTap: () => _editMarkerData(index),
                        );
                      },
                    ),
                  )
                : null),
    );
  }
}
