import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:light_sensor/light_sensor.dart';
import 'dart:async';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:printing/printing.dart'; // Für stabiles PDF-Rendering
import 'package:url_launcher/url_launcher.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'save_helper.dart' if (dart.library.html) 'save_helper_web.dart';
import 'pdf_helper.dart';

import 'widgets/bluetooth_service.dart';
import 'widgets/help_dialog.dart';
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
  bool _isEnglish = false;

  String _l(String de, String en) => _isEnglish ? en : de;
  String _appVersion = '';

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
  bool _isBluetoothConnecting = false;

  // Aktuelle Sensorwerte
  DateTime _lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  String _rawBluetoothData = 'Keine Daten';

  @override
  void initState() {
    super.initState();
    _projectDate = _getFormattedDateTime();
    _initLightSensor();
    _initPackageInfo();
  }

  Future<void> _initPackageInfo() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        // Format: 1.0.0 (Build 1)
        _appVersion = '${info.version} (Build ${info.buildNumber})';
      });
    }
  }

  @override
  void dispose() {
    _lightSubscription?.cancel();
    AppBluetoothService.disconnect();
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
    setState(() => _isBluetoothConnecting = true);

    try {
      // FIX: Breche die Simulation oder den internen Sensor-Stream ab,
      // damit die Werte nicht mit den Bluetooth-Daten kollidieren.
      await _lightSubscription?.cancel();
      _lightSubscription = null;

      await AppBluetoothService.connectAndListen(_handleBluetoothData);

      if (mounted) {
        // The device name is not directly available here after connectAndListen,
        // but we can assume connection if no error was thrown.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _l(
                'Verbunden mit externem Bluetooth-Sensor.',
                'Connected to external Bluetooth sensor.',
              ),
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      debugPrint('Bluetooth Fehler: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${_l('Verbindung fehlgeschlagen', 'Connection failed')}: $e',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isBluetoothConnecting = false);
    }
  }

  void _handleBluetoothData(String uuid, Uint8List data) {
    try {
      final ByteData byteData = ByteData.view(data.buffer);

      // Parsing basierend auf der UUID
      if (uuid == AppBluetoothService.txCharUuid &&
          byteData.lengthInBytes >= 4) {
        final newValue = byteData.getFloat32(0, Endian.little);
        final now = DateTime.now();

        // UI-Update drosseln (max 10 Hz), um Performance-Einbrüche zu vermeiden
        if (now.difference(_lastUiUpdate).inMilliseconds > 100) {
          if (mounted) {
            setState(() {
              _rawBluetoothData = data
                  .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
                  .join(' ');
              _currentLightValue = newValue;
              _hasHardwareSensor = true;
            });
          }
          _lastUiUpdate = now;
        } else {
          // Wert intern aktualisieren, damit er beim nächsten regulären Rebuild aktuell ist
          _currentLightValue = newValue;
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

  // Beleuchtungsmessungstyp und Standardhöhe
  String _selectedMeasurementType = 'Allgemeinbeleuchtung';
  double _defaultMeasurementHeight =
      0.75; // Initialwert für Allgemeinbeleuchtung
  final Map<String, double> _measurementTypeOptions = {
    'Allgemeinbeleuchtung': 0.75,
    'Sicherheitsbeleuchtung': 0.20,
    'Treppen': 0.20,
    'Parkbauten': 0.20,
  };

  Future<void> _confirmReset() async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_l('Neustart bestätigen', 'Confirm Reset')),
        content: Text(
          _l(
            'Möchten Sie wirklich alle Messpunkte löschen und neu starten?',
            'Do you really want to delete all measurement points and start over?',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_l('Abbrechen', 'Cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_l('Bestätigen', 'Confirm')),
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
        _selectedMeasurementType = 'Allgemeinbeleuchtung';
        _defaultMeasurementHeight = 0.75;
        _calibrationEnd = null;
        _currentMousePosition = null;
        _transformationController.value = Matrix4.identity();
      });
    }
  }

  void _fitPdfToScreen() {
    if (_pdfSize == null ||
        _viewportSize == null ||
        _pdfSize!.width == 0 ||
        _pdfSize!.height == 0) {
      return;
    }

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

  Future<void> _pickFloorPlan() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png'],
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

          Uint8List? finalBytes;
          Size? finalSize;
          final String extension = platformFile.extension?.toLowerCase() ?? '';

          if (extension == 'pdf') {
            // PDF Handling
            final double targetDpi =
                (kIsWeb &&
                    (defaultTargetPlatform == TargetPlatform.android ||
                        defaultTargetPlatform == TargetPlatform.iOS))
                ? 150
                : 300;

            await for (var page in Printing.raster(
              bytes,
              pages: [0],
              dpi: targetDpi,
            )) {
              finalBytes = await page.toPng();
              finalSize = Size(page.width.toDouble(), page.height.toDouble());
              break;
            }
          } else {
            // Bild Handling (jpg, png)
            finalBytes = bytes;
            final decodedImage = await decodeImageFromList(bytes);
            finalSize = Size(
              decodedImage.width.toDouble(),
              decodedImage.height.toDouble(),
            );
          }

          if (finalBytes != null && finalSize != null) {
            setState(() {
              _pdfBytes = finalBytes;
              _pdfSize = finalSize;
              _areas.clear();
              _areas.add(MeasurementArea(name: _l('Allgemein', 'General')));
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
              _transformationController.value = Matrix4.identity();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _fitPdfToScreen();
              });
              _isLoading = false;
            });
          }
        }
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${_l('Fehler beim Laden des Grundrisses', 'Error loading floor plan')}: ${e.toString()}',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  /// Ermöglicht das Scannen eines Dokuments (Native) oder Kamera-Upload (Web)
  Future<void> _scanFloorPlan() async {
    if (kIsWeb) {
      // Im Web nutzen wir den FilePicker mit dem Hinweis auf die Kamera
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _l(
              'Nutzen Sie im folgenden Dialog "Kamera" oder "Dokument scannen".',
              'Use "Camera" or "Scan Document" in the following dialog.',
            ),
          ),
          duration: Duration(seconds: 3),
        ),
      );
      _pickFloorPlan();
      return;
    }

    // Hinweis: Für native Plattformen (Android/iOS) müsste das Paket 'edge_detection'
    // oder 'google_mlkit_document_scanner' in der pubspec.yaml hinzugefügt werden.
    try {
      setState(() => _isLoading = true);

      // Beispiel-Logik für eine native Scanner-Integration:
      // final String? imagePath = await EdgeDetection.detectEdge(
      //   saveTo: (await getTemporaryDirectory()).path + '/scan.png',
      //   canUseGallery: true,
      //   androidScanTitle: 'Grundriss scannen',
      //   androidConfirmButtonText: 'Fertig',
      // );

      // Da wir hier im Code-Kontext bleiben, simulieren wir die Verarbeitung
      // eines Pfades, falls du eine Scanner-Library einbindest:
      /*
      if (imagePath != null) {
        final File imageFile = File(imagePath);
        final Uint8List bytes = await imageFile.readAsBytes();
        final decodedImage = await decodeImageFromList(bytes);
        
        setState(() {
          _pdfBytes = bytes;
          _pdfSize = Size(decodedImage.width.toDouble(), decodedImage.height.toDouble());
          _areas.clear();
          _areas.add(MeasurementArea(name: 'Scan - ${DateTime.now().hour}:${DateTime.now().minute}'));
          _selectedAreaIndex = 0;
          _isLoading = false;
        });
        _fitPdfToScreen();
      }
      */

      // Vorläufiger Fallback, solange kein natives Paket aktiv ist:
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Scanner-Modul für native App bereit zur Aktivierung.'),
        ),
      );
    } catch (e) {
      setState(() => _isLoading = false);
      debugPrint('Scan Fehler: $e');
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${_l('Logo-Fehler', 'Logo Error')}: $e')),
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
    if (_calibrationStart == null || _calibrationEnd == null) {
      return;
    }

    final controller = TextEditingController(text: '5.0');
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_l('Maßstab festlegen', 'Set Scale')),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: _l('Länge in Meter', 'Length in meters'),
          ),
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
            child: Text(_l('Abbrechen', 'Cancel')),
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

    // Lokaler Zustand für den Dialog
    String dialogSelectedMeasurementType = _selectedMeasurementType;
    double dialogDefaultMeasurementHeight = _defaultMeasurementHeight;

    final TextEditingController heightInputController = TextEditingController(
      text: dialogDefaultMeasurementHeight.toString(),
    );

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setStateDialog) {
          return AlertDialog(
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
                    decoration: const InputDecoration(
                      labelText: 'Prüfer / Person',
                    ),
                  ),
                  TextField(
                    controller: dateController,
                    decoration: const InputDecoration(
                      labelText: 'Datum / Uhrzeit',
                    ),
                  ),
                  TextField(
                    controller: dController,
                    decoration: const InputDecoration(
                      labelText: 'Verwendete Geräte',
                    ),
                  ),
                  DropdownButtonFormField<String>(
                    value: dialogSelectedMeasurementType,
                    decoration: const InputDecoration(
                      labelText: 'Art der Beleuchtungsmessung',
                    ),
                    items: _measurementTypeOptions.keys.map((String type) {
                      return DropdownMenuItem<String>(
                        value: type,
                        child: Text(type),
                      );
                    }).toList(),
                    onChanged: (String? newValue) {
                      if (newValue != null) {
                        setStateDialog(() {
                          dialogSelectedMeasurementType = newValue;
                          dialogDefaultMeasurementHeight =
                              _measurementTypeOptions[newValue] ??
                              0.75; // Update internal value
                          heightInputController.text =
                              dialogDefaultMeasurementHeight
                                  .toString(); // Update TextField
                        });
                      }
                    },
                  ),
                  TextField(
                    controller: heightInputController,
                    keyboardType: TextInputType.number,
                    onChanged: (value) {
                      dialogDefaultMeasurementHeight =
                          double.tryParse(value) ?? 0.75;
                    },
                    decoration: InputDecoration(
                      labelText: _l(
                        'Standard-Messebene / Höhe',
                        'Standard Reference Plane / Height',
                      ),
                    ),
                  ),
                  TextField(
                    controller: nController,
                    maxLines: 3,
                    decoration: InputDecoration(
                      labelText: _l(
                        'Infos(Lux-Werte, etc.)',
                        'Notes (Lux values, etc.)',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(_l('Abbrechen', 'Cancel')),
              ),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _projectName = pController.text;
                    _surveyorName = sController.text;
                    _projectDate = dateController.text;
                    _usedDevices = dController.text;
                    _additionalNotes = nController.text;
                    _selectedMeasurementType = dialogSelectedMeasurementType;
                    _defaultMeasurementHeight =
                        double.tryParse(heightInputController.text) ?? 0.75;
                  });
                  Navigator.pop(context);
                },
                child: Text(_l('Speichern', 'Save')),
              ),
            ],
          );
        },
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
        title: Text(_l('Neuer Bereich / Raum', 'New Area / Room')),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: _l('Name des Bereichs', 'Area Name'),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_l('Abbrechen', 'Cancel')),
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
            child: Text(_l('Erstellen', 'Create')),
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
        title: Text(_l('Bereich umbenennen', 'Rename Area')),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(labelText: _l('Neuer Name', 'New Name')),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_l('Abbrechen', 'Cancel')),
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
            child: Text(_l('Speichern', 'Save')),
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
              decoration: InputDecoration(
                labelText: _l(
                  'Bezeichnung (z.B. Zone, Tisch, etc.)',
                  'Label (e.g. Zone, Desk, etc.)',
                ),
              ),
            ),
            TextField(
              controller: heightController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: _l('Messhöhe (m)', 'Measurement Height (m)'),
                suffixText: 'm',
              ),
            ),
            TextField(
              controller: valueController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: _l('Sensorwert (Lux)', 'Sensor Value (Lux)'),
              ),
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
                    ? '${_l('Sensorwert übernehmen', 'Use sensor value')} (${calibratedLightValue.toStringAsFixed(1)} lx)'
                    : _l('Sensor simulieren', 'Simulate sensor'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_l('Abbrechen', 'Cancel')),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _currentPoints.removeAt(index);
              });
              Navigator.pop(context);
            },
            child: Text(
              _l('Marker löschen', 'Delete Marker'),
              style: TextStyle(color: Colors.red),
            ),
          ),
          if (_areas.length > 1)
            TextButton(
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text(_l('Bereich löschen?', 'Delete Area?')),
                    content: Text(
                      _l(
                        'Soll der Bereich "${_areas[_selectedAreaIndex].name}" inklusive aller Punkte gelöscht werden?',
                        'Should the area "${_areas[_selectedAreaIndex].name}" including all points be deleted?',
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text(_l('Nein', 'No')),
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
                        child: Text(_l('Ja, löschen', 'Yes, delete')),
                      ),
                    ],
                  ),
                );
              },
              child: Text(
                _l('Bereich löschen', 'Delete Area'),
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
            child: Text(_l('Speichern', 'Save')),
          ),
        ],
      ),
    );
  }

  Future<void> _exportToPdf() async {
    if (_pdfBytes == null || _isExportingPdf) return;

    final bool hasAnyPoints = _areas.any((area) => area.markers.isNotEmpty);
    if (!hasAnyPoints) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _l(
              'Bitte füge zuerst Messpunkte hinzu',
              'Please add measurement points first',
            ),
          ),
        ),
      );
      return;
    }

    setState(() => _isExportingPdf = true);

    // Kleiner Delay, damit der Lade-Overlay sofort sichtbar wird
    await Future.delayed(const Duration(milliseconds: 500));

    try {
      debugPrint('Main: Starte PDF Export...');

      await PdfHelper.exportToPdf(
        floorPlanBytes: _pdfBytes!, // ← bleibt gleich
        logoBytes: _logoBytes,
        pdfSize: _pdfSize!,
        projectName: _projectName,
        surveyorName: _surveyorName,
        projectDate: _projectDate,
        usedDevices: _usedDevices,
        additionalNotes: _additionalNotes,
        selectedMeasurementType: _selectedMeasurementType,
        areas: _areas,
        referencePoint: _referencePoint,
        pixelsPerMeter: _pixelsPerMeter,
        markerSize: _markerSize,
        isEnglish: _isEnglish, // <-- Neuer Parameter
      );

      debugPrint('Main: Export erfolgreich beendet.');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _l(
                'PDF wurde erfolgreich erstellt!',
                'PDF created successfully!',
              ),
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e, stack) {
      debugPrint('PDF Fehler: $e');
      debugPrint(stack.toString());

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${_l('Fehler beim PDF-Export', 'Error during PDF export')}: ${e.toString()}',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isExportingPdf = false);
      }
    }
  }

  Offset _snapToGridOffset(Offset pos) {
    if (!_showGrid || !_snapToGrid) {
      return pos;
    }
    final double gx = _gridSizeX * _pixelsPerMeter;
    final double gy = _gridSizeY * _pixelsPerMeter;
    return Offset(
      ((pos.dx - _gridOffset.dx) / gx).round() * gx + _gridOffset.dx,
      ((pos.dy - _gridOffset.dy) / gy).round() * gy + _gridOffset.dy,
    );
  }

  Future<void> _saveProject() async {
    if (_pdfBytes == null) {
      return;
    }

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
        'selectedMeasurementType': _selectedMeasurementType,
        'defaultMeasurementHeight': _defaultMeasurementHeight,
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

      // Dateiname basierend auf Projektname oder Fallback
      final String fileName = _projectName.trim().isEmpty
          ? 'Lightmeter_Projekt'
          : _projectName.trim();
      final success = await saveProjectFile(bytes, '$fileName.lmp');

      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _l(
                'Projekt erfolgreich gespeichert',
                'Project saved successfully',
              ),
            ),
          ),
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
            _selectedMeasurementType =
                data['selectedMeasurementType'] ?? 'Allgemeinbeleuchtung';
            _defaultMeasurementHeight =
                data['defaultMeasurementHeight'] ?? 0.75;
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
            tooltip: _l('Maßstab setzen', 'Set Scale'),
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
                    SnackBar(
                      content: Text(
                        _l(
                          'Klicken Sie auf den gewünschten Nullpunkt (z.B. unten links).',
                          'Click on the desired zero point (e.g., bottom left).',
                        ),
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
            icon: const Icon(Icons.document_scanner),
            onPressed: _scanFloorPlan,
            tooltip: 'Grundriss scannen',
          ),
          IconButton(
            icon: const Icon(Icons.lightbulb_outline),
            onPressed: () =>
                setState(() => _showSensorSheet = !_showSensorSheet),
            tooltip: 'Sensorwerte anzeigen',
          ),
          IconButton(
            icon: Icon(
              Icons.bluetooth,
              color: AppBluetoothService.isConnected ? Colors.blue : null,
            ),
            onPressed: _isBluetoothConnecting ? null : _connectExternalSensor,
            tooltip: _l(
              'Externen Bluetooth-Sensor verbinden',
              'Connect External Bluetooth Sensor',
            ),
          ),
          IconButton(
            icon: _isExportingPdf
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2.5,
                    ),
                  )
                : const Icon(Icons.picture_as_pdf),
            onPressed: _pdfBytes != null && !_isExportingPdf
                ? _exportToPdf
                : null,
            tooltip: _l('Export als PDF', 'Export as PDF'),
          ),
          IconButton(
            icon: const Icon(Icons.folder),
            onPressed: _pickFloorPlan,
            tooltip: _l(
              'Grundriss laden (PDF/Bild)',
              'Load Floor Plan (PDF/Image)',
            ),
          ),
          IconButton(
            icon: const Icon(Icons.brightness_6),
            onPressed: () => context.read<ThemeProvider>().toggleTheme(),
            tooltip: _l('Theme umschalten', 'Toggle Theme'),
          ),
          IconButton(
            icon: const Icon(Icons.color_lens),
            onPressed: _showColorPicker,
            tooltip: _l('Hintergrundfarbe', 'Background Color'),
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
              child: Text(
                _l('Menü', 'Menu'),
                style: const TextStyle(color: Colors.white, fontSize: 24),
              ),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.language),
              title: const Text('English Language'),
              value: _isEnglish,
              onChanged: (val) => setState(() => _isEnglish = val),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.file_open),
              title: Text(_l('Projekt laden', 'Load Project')),
              subtitle: Text(
                _l('Gespeichertes Projekt öffnen', 'Open a saved project'),
              ),
              onTap: () {
                Navigator.pop(context);
                _loadProject();
              },
            ),

            ListTile(
              leading: const Icon(Icons.save),
              title: Text(_l('Projekt speichern', 'Save Project')),
              subtitle: Text(
                _l('Aktuellen Stand sichern', 'Save current progress'),
              ),
              onTap: () {
                Navigator.pop(context);
                _saveProject();
              },
            ),
            ListTile(
              leading: const Icon(Icons.add_photo_alternate),
              title: Text(_l('Logo hochladen', 'Upload Logo')),
              trailing: _logoBytes != null
                  ? Image.memory(_logoBytes!, height: 30)
                  : const Text(
                      'By OvW',
                      style: TextStyle(color: Colors.grey, fontSize: 10),
                    ),
              subtitle: Text(
                _l('Erscheint im PDF-Kopf', 'Appears in PDF header'),
              ),
              onTap: () {
                Navigator.pop(context);
                _pickLogo();
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(_l('Projekt-Infos bearbeiten', 'Edit Project Info')),
              subtitle: Text(
                _l('Name, Messgerät, Notizen', 'Name, Device, Notes'),
              ),
              onTap: () {
                Navigator.pop(context);
                _showProjectInfoDialog();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete),
              title: Text(_l('Messpunkte löschen', 'Delete Points')),
              onTap: () {
                Navigator.pop(context);
                setState(() => _currentPoints.clear());
              },
            ),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: Text(_l('Neustart', 'Restart')),
              onTap: () {
                Navigator.pop(context);
                _confirmReset();
              },
            ),
            ListTile(
              leading: const Icon(Icons.help_center_outlined),
              title: Text(_l('Hilfe & Anleitung', 'Help & Guide')),
              subtitle: Text(
                _l('App-Handbuch und Lux-Tabelle', 'App manual and Lux table'),
              ),
              onTap: () {
                Navigator.pop(context);
                showHelpDialog(context, _isEnglish, _appVersion);
              },
            ),
            ListTile(
              leading: const Icon(Icons.sensors),
              title: Text(_l('Sensorkalibrierung', 'Sensor Calibration')),
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
                _l('Hilfsraster', 'Guide Grid'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.grid_4x4),
              title: Text(_l('Raster anzeigen', 'Show Grid')),
              value: _showGrid,
              onChanged: (val) => setState(() => _showGrid = val),
            ),
            if (_showGrid) ...[
              SwitchListTile(
                secondary: const Icon(Icons.pin_drop),
                title: Text(_l('Am Raster andocken', 'Snap to Grid')),
                value: _snapToGrid,
                onChanged: (val) => setState(() => _snapToGrid = val),
              ),
              ListTile(
                title: Text(
                  '${_l('X-Raster', 'X-Grid')}: ${_gridSizeX.toStringAsFixed(1)} m',
                ),
                subtitle: Slider(
                  value: _gridSizeX,
                  min: 0.5,
                  max: 20.0,
                  divisions: 39,
                  onChanged: (val) => setState(() => _gridSizeX = val),
                ),
              ),
              ListTile(
                title: Text(
                  '${_l('Y-Raster', 'Y-Grid')}: ${_gridSizeY.toStringAsFixed(1)} m',
                ),
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
                title: Text(_l('Raster verschieben', 'Move Grid')),
                subtitle: Text(
                  _l('Maus ziehen zum Bewegen', 'Drag mouse to move'),
                ),
                value: _isMovingGrid,
                onChanged: (val) => setState(() => _isMovingGrid = val),
              ),
              ListTile(
                leading: const Icon(Icons.restore),
                title: Text(_l('Position zurücksetzen', 'Reset Position')),
                onTap: () {
                  setState(() {
                    _gridOffset = Offset.zero;
                  });
                },
              ),
              ListTile(
                leading: const Icon(Icons.gps_fixed),
                title: Text(
                  _l('Referenzpunkt zurücksetzen', 'Reset Reference Point'),
                ),
                onTap: () {
                  setState(() => _referencePoint = Offset.zero);
                  Navigator.pop(context);
                },
              ),
            ],
            const Divider(),
            ListTile(
              leading: const Icon(Icons.straighten),
              title: Text(_l('Marker-Größe', 'Marker Size')),
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
                  Padding(
                    padding: const EdgeInsets.only(left: 16, right: 8),
                    child: Text(
                      '${_l('Bereiche', 'Areas')} :',
                      style: const TextStyle(fontWeight: FontWeight.bold),
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
                    tooltip: _l('Neuen Bereich anlegen', 'Create new area'),
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
                      onPressed: _pickFloorPlan,
                      child: Text(
                        _l(
                          'Grundriss laden (PDF/Bild)',
                          'Load Floor Plan (PDF/Image)',
                        ),
                      ),
                    ),
                  )
                else
                  LayoutBuilder(
                    // New: Use LayoutBuilder to get the available size for the PDF
                    builder: (context, constraints) {
                      final newSize = constraints.biggest;

                      // Verhindert unnötige Rebuilds während der BottomSheet-Animation
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        // Nur aktualisieren, wenn sich die Größe signifikant geändert hat (> 1 Pixel)
                        if (mounted &&
                            (_viewportSize == null ||
                                (_viewportSize!.height - newSize.height).abs() >
                                    1)) {
                          setState(() {
                            _viewportSize = newSize;
                            _fitPdfToScreen();
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
                                gaplessPlayback: true,
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
                                    if (_isMovingGrid) {
                                      return;
                                    }
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
                                            height: _defaultMeasurementHeight,
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
                                  left:
                                      marker.position.dx -
                                      (_markerSize *
                                          4), // Breite an _markerSize anpassen
                                  bottom: _pdfSize!.height - marker.position.dy,
                                  width:
                                      _markerSize *
                                      8, // Breite an _markerSize anpassen
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
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.center,
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

                // Sensor-Panel / Messpunkt-Liste als Overlay (verhindert Layout-Loops)
                if (_showSensorSheet)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 600),
                        height: 200,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Theme.of(context).cardColor,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(16),
                          ),
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
                                Text(
                                  _l(
                                    'Sensorkalibrierung',
                                    'Sensor Calibration',
                                  ),
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
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
                                        ? _l(
                                            'Hardware-Sensor aktiv',
                                            'Hardware sensor active',
                                          )
                                        : _l(
                                            'Simulations-Modus',
                                            'Simulation mode',
                                          ),
                                    style: TextStyle(
                                      color: _hasHardwareSensor
                                          ? Colors.green
                                          : Colors.orange,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  icon: Icon(Icons.bluetooth),
                                  color: AppBluetoothService.isConnected
                                      ? Colors.blue
                                      : null,
                                  onPressed: _isBluetoothConnecting
                                      ? null
                                      : _connectExternalSensor,
                                  tooltip: _l(
                                    'Externen Bluetooth-Sensor verbinden',
                                    'Connect external Bluetooth sensor',
                                  ),
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
                                const Icon(
                                  Icons.lightbulb,
                                  color: Colors.orange,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _hasHardwareSensor &&
                                            _currentLightValue == null
                                        ? _l(
                                            'Warte auf Sensordaten...',
                                            'Waiting for sensor data...',
                                          )
                                        : '${_l('Aktuell', 'Current')}: ${_currentLightValue?.toStringAsFixed(1) ?? "---"} lx',
                                    style: const TextStyle(fontSize: 16),
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  '${_l('Kalibriert', 'Calibrated')}: ${(_currentLightValue != null ? (_currentLightValue! * _lightCalibrationFactor) : 0.0).toStringAsFixed(1)} lx',
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
                                Text('${_l('Faktor', 'Factor')}: '),
                                Expanded(
                                  child: Slider(
                                    value: _lightCalibrationFactor,
                                    min: 0.01,
                                    max: 3.0,
                                    divisions: 299,
                                    label: _lightCalibrationFactor
                                        .toStringAsFixed(2),
                                    onChanged: (val) => setState(
                                      () => _lightCalibrationFactor = val,
                                    ),
                                  ),
                                ),
                                Text(
                                  _lightCalibrationFactor.toStringAsFixed(2),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.black12,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '${_l('Rohdaten (Hex)', 'Raw Data (Hex)')}: $_rawBluetoothData',
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                  color: Colors.blueGrey,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                else if (_currentPoints.isNotEmpty)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 600),
                        height: 120,
                        decoration: BoxDecoration(
                          color: Theme.of(context).cardColor,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(16),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black12,
                              blurRadius: 5,
                              offset: const Offset(0, -2),
                            ),
                          ],
                        ),
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
                              dense: true,
                              leading: CircleAvatar(
                                radius: 12,
                                backgroundColor: Theme.of(context).primaryColor,
                                child: Text(
                                  '${index + 1}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                  ),
                                ),
                              ),
                              title: Text(
                                '${_areas[_selectedAreaIndex].name} - ${marker.label.isNotEmpty ? marker.label : index + 1} (h: ${marker.height}m)',
                                style: const TextStyle(fontSize: 12),
                              ),
                              subtitle: Text(
                                'Pos: ${realX.toStringAsFixed(2)}m / ${realY.toStringAsFixed(2)}m ${marker.sensorValue != null ? "| ${_l('Wert', 'Value')}: ${marker.sensorValue} Lux" : ""}',
                                style: const TextStyle(fontSize: 10),
                              ),
                              onTap: () => _editMarkerData(index),
                            );
                          },
                        ),
                      ),
                    ),
                  ),

                if (_isLoading || _isExportingPdf)
                  Container(
                    color: Colors.black.withOpacity(0.5),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(color: Colors.white),
                        const SizedBox(height: 16),
                        Text(
                          _isExportingPdf
                              ? _l(
                                  'PDF wird generiert...\nDies kann 5–15 Sekunden dauern',
                                  'Generating PDF...\nThis may take 5–15 seconds',
                                )
                              : '',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white, fontSize: 16),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
