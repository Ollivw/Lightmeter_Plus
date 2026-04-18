import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'models/measurement_models.dart';

class PdfHelper {
  /// Haupt-Einstiegspunkt – ruft die PDF-Erstellung im Hintergrund auf
  static Future<void> exportToPdf({
    required Uint8List floorPlanBytes,
    required Uint8List? logoBytes,
    required Size pdfSize,
    required String projectName,
    required String surveyorName,
    required String projectDate,
    required String usedDevices,
    required String additionalNotes,
    required String selectedMeasurementType,
    required List<MeasurementArea> areas,
    required Offset referencePoint,
    required double pixelsPerMeter,
    required double markerSize,
    required bool isEnglish,
  }) async {
    debugPrint('PdfHelper: Starte optimierte PDF-Generierung...');

    // Alles schwere in compute() auslagern
    final pdfBytes = await compute(
      _buildPdfDocument,
      _PdfParams(
        floorPlanBytes:
            floorPlanBytes, // Nutze direkt die DPI-optimierten Bytes
        logoBytes: logoBytes,
        pdfSize: pdfSize,
        projectName: projectName,
        surveyorName: surveyorName,
        projectDate: projectDate,
        usedDevices: usedDevices,
        additionalNotes: additionalNotes,
        selectedMeasurementType: selectedMeasurementType,
        areas: areas,
        referencePoint: referencePoint,
        pixelsPerMeter: pixelsPerMeter,
        markerSize: markerSize,
        isEnglish: isEnglish,
      ),
    );

    final String fileName = projectName.isNotEmpty
        ? projectName
        : 'Lichtmessung_Report';

    // 3. PDF anzeigen / drucken
    if (kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android)) {
      // Auf mobilen Web-Browsern (iPad/iPhone/Android) ist sharePdf wesentlich zuverlässiger,
      // da layoutPdf (Druckdialog) häufig von Popup-Blockern unterdrückt wird.
      await Printing.sharePdf(bytes: pdfBytes, filename: '$fileName.pdf');
    } else {
      await Printing.layoutPdf(
        onLayout: (PdfPageFormat format) async => pdfBytes,
        name: fileName,
      );
    }

    debugPrint(
      'PdfHelper: PDF erfolgreich generiert (${pdfBytes.length ~/ 1024} KB)',
    );
  }

  /// Diese Funktion läuft im Isolate (compute)
  static Future<Uint8List> _buildPdfDocument(_PdfParams params) async {
    final pdf = pw.Document();

    final floorImage = pw.MemoryImage(params.floorPlanBytes);
    final logoImage = params.logoBytes != null
        ? pw.MemoryImage(params.logoBytes!)
        : null;

    // ====================== SEITE 1: GRUNDRISS ======================
    final bool isLandscape = params.pdfSize.width > params.pdfSize.height;

    pdf.addPage(
      pw.Page(
        pageFormat: isLandscape ? PdfPageFormat.a4.landscape : PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(
          0,
          0,
          0,
          20,
        ), // Unten Platz für Seitenzahl lassen
        build: (pw.Context context) {
          return pw.Stack(
            children: [
              pw.Center(
                child: pw.FittedBox(
                  fit: pw.BoxFit.contain,
                  child: pw.SizedBox(
                    width: params.pdfSize.width,
                    height: params.pdfSize.height,
                    child: pw.Stack(
                      children: [
                        pw.Image(floorImage, fit: pw.BoxFit.fill),
                        if (params.referencePoint != Offset.zero)
                          _buildReferencePoint(
                            params.referencePoint,
                            params.markerSize,
                          ),
                        ..._buildAllMarkers(params),
                      ],
                    ),
                  ),
                ),
              ),
              pw.Align(
                alignment: pw.Alignment.bottomRight,
                child: _buildFooter(context, params.isEnglish),
              ),
            ],
          );
        },
      ),
    );

    // ====================== DETAILSEITEN ======================
    for (final area in params.areas) {
      if (area.markers.isEmpty) continue;

      final stats = _calculateAreaStats(area.markers);

      final tableData = _buildTableData(
        area.markers,
        params.referencePoint,
        params.pixelsPerMeter,
      );

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          footer: (context) => _buildFooter(context, params.isEnglish),
          margin: const pw.EdgeInsets.all(40),
          build: (pw.Context context) => [
            _buildHeader(logoImage, params.isEnglish),
            pw.SizedBox(height: 20),
            _buildTitle(area.name, params.isEnglish),
            pw.SizedBox(height: 15),
            _buildProjectInfo(params, area),
            pw.SizedBox(height: 25),
            if (stats.hasValues) _buildStatsRow(stats, params.isEnglish),
            pw.SizedBox(height: 30),
            ..._buildPagedTables(tableData, params.isEnglish),
          ],
        ),
      );
    }

    return pdf.save();
  }

  // ==================== Hilfsmethoden ====================

  static pw.Widget _buildFooter(pw.Context context, bool isEnglish) {
    return pw.Container(
      alignment: pw.Alignment.centerRight,
      margin: const pw.EdgeInsets.only(top: 10, right: 20),
      child: pw.Text(
        '${isEnglish ? "Page" : "Seite"} ${context.pageNumber} ${isEnglish ? "of" : "von"} ${context.pagesCount}',
        style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey),
      ),
    );
  }

  static pw.Widget _buildHeader(pw.MemoryImage? logo, bool isEnglish) {
    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 15),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          if (logo != null)
            pw.Image(logo, height: 45)
          else
            pw.Text(
              'By OvW',
              style: pw.TextStyle(fontSize: 13, color: PdfColors.grey),
            ),
          pw.Text(
            'Lightmeter Pro Report',
            style: pw.TextStyle(fontSize: 11, color: PdfColors.grey),
          ),
        ],
      ),
    );
  }

  static pw.Widget _buildTitle(String areaName, bool isEnglish) {
    return pw.Text(
      '${isEnglish ? "Measurement Report" : "Messbericht"} - $areaName',
      style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold),
    );
  }

  static pw.Widget _buildProjectInfo(_PdfParams p, MeasurementArea area) {
    final t = p.isEnglish ? _en : _de;
    return pw.Container(
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        color: PdfColors.grey100,
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                '${t['project']}: ${p.projectName.isEmpty ? (p.isEnglish ? "Unnamed" : "Unbenannt") : p.projectName}',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              ),
              pw.Text('${t['date']}: ${p.projectDate}'),
            ],
          ),
          pw.Divider(color: PdfColors.grey300),
          pw.Text(
            '${t['surveyor']}: ${p.surveyorName.isEmpty ? "-" : p.surveyorName}',
          ),
          pw.Text(
            '${t['devices']}: ${p.usedDevices.isEmpty ? "-" : p.usedDevices}',
          ),
          pw.Text(
            '${t['measurement']}: ${p.isEnglish ? _translateType(p.selectedMeasurementType) : p.selectedMeasurementType}',
          ),
          if (p.additionalNotes.isNotEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 8),
              child: pw.Text(
                '${t['notes']}: ${p.additionalNotes}',
                style: pw.TextStyle(
                  fontStyle: pw.FontStyle.italic,
                  color: PdfColors.grey700,
                ),
              ),
            ),
        ],
      ),
    );
  }

  static pw.Widget _buildStatsRow(AreaStats stats, bool isEnglish) {
    final t = isEnglish ? _en : _de;
    return pw.Row(
      children: [
        _statCard(
          t['min']!,
          '${stats.min!.toStringAsFixed(1)} lx',
          PdfColors.blueGrey700,
        ),
        _statCard(
          t['avg']!,
          '${stats.mean!.toStringAsFixed(1)} lx',
          PdfColors.blue700,
        ),
        _statCard(
          t['max']!,
          '${stats.max!.toStringAsFixed(1)} lx',
          PdfColors.teal700,
        ),
        _statCard(
          t['uni']!,
          stats.uniformity.toStringAsFixed(2),
          PdfColors.cyan700,
        ),
      ],
    );
  }

  static pw.Widget _statCard(String title, String value, PdfColor color) {
    return pw.Expanded(
      child: pw.Container(
        margin: const pw.EdgeInsets.symmetric(horizontal: 4),
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(
          color: color,
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
        ),
        child: pw.Column(
          children: [
            pw.Text(
              title,
              style: pw.TextStyle(color: PdfColors.white, fontSize: 9),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              value,
              style: pw.TextStyle(
                color: PdfColors.white,
                fontWeight: pw.FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static List<pw.Widget> _buildPagedTables(
    List<List<String>> tableData,
    bool isEnglish,
  ) {
    final t = isEnglish ? _en : _de;
    const chunkSize = 20;
    final chunks = <List<List<String>>>[];

    for (var i = 0; i < tableData.length; i += chunkSize) {
      chunks.add(
        tableData.sublist(
          i,
          i + chunkSize > tableData.length ? tableData.length : i + chunkSize,
        ),
      );
    }

    return chunks.map((chunk) {
      return pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 12),
        child: pw.TableHelper.fromTextArray(
          border: null,
          headerDecoration: const pw.BoxDecoration(
            color: PdfColors.blueGrey900,
          ),
          headerStyle: pw.TextStyle(
            color: PdfColors.white,
            fontWeight: pw.FontWeight.bold,
          ),
          cellHeight: 26,
          columnWidths: {
            0: const pw.FixedColumnWidth(30),
            1: const pw.FlexColumnWidth(3),
            2: const pw.FlexColumnWidth(2.2),
            3: const pw.FixedColumnWidth(55),
            4: const pw.FixedColumnWidth(75),
          },
          headers: ['#', t['label']!, t['pos']!, t['height']!, t['value']!],
          data: chunk,
        ),
      );
    }).toList();
  }

  static pw.Widget _buildReferencePoint(Offset pos, double markerSize) {
    return pw.Positioned(
      left: pos.dx - markerSize / 2,
      top: pos.dy - markerSize / 2,
      child: pw.SizedBox(
        width: markerSize,
        height: markerSize,
        child: pw.Stack(
          children: [
            pw.Center(
              child: pw.Container(
                width: markerSize,
                height: 2,
                color: PdfColors.blue,
              ),
            ),
            pw.Center(
              child: pw.Container(
                width: 2,
                height: markerSize,
                color: PdfColors.blue,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static List<pw.Widget> _buildAllMarkers(_PdfParams params) {
    final widgets = <pw.Widget>[];
    final markerSize = params.markerSize;

    for (final area in params.areas) {
      for (var i = 0; i < area.markers.length; i++) {
        final marker = area.markers[i];
        widgets.add(
          pw.Positioned(
            left: marker.position.dx - (markerSize * 4),
            bottom:
                params.pdfSize.height - marker.position.dy - (markerSize * 0.3),
            child: pw.SizedBox(
              width: markerSize * 8,
              child: pw.Column(
                mainAxisSize: pw.MainAxisSize.min,
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  pw.Text(
                    area.name,
                    style: pw.TextStyle(
                      fontSize: markerSize * 0.28,
                      color: PdfColors.grey700,
                    ),
                  ),
                  pw.Text(
                    marker.label.isNotEmpty ? marker.label : '${i + 1}',
                    style: pw.TextStyle(
                      fontSize: markerSize * 0.52,
                      color: PdfColors.red,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  if (marker.sensorValue != null)
                    pw.Text(
                      _formatLux(marker.sensorValue!),
                      style: pw.TextStyle(
                        fontSize: markerSize * 0.48,
                        color: PdfColors.green,
                      ),
                    ),
                  pw.Container(
                    width: markerSize * 0.6,
                    height: markerSize * 0.6,
                    decoration: const pw.BoxDecoration(
                      color: PdfColors.red,
                      shape: pw.BoxShape.circle,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }
    }
    return widgets;
  }

  static String _formatLux(double value) {
    if (value > 20) return '${value.round()} lx';
    return value == value.roundToDouble()
        ? '${value.toInt()} lx'
        : '${value.toStringAsFixed(1)} lx';
  }

  static AreaStats _calculateAreaStats(List<MeasurementMarker> markers) {
    final values = markers
        .map((m) => m.sensorValue)
        .whereType<double>()
        .toList();
    if (values.isEmpty) return AreaStats();

    final min = values.reduce((a, b) => a < b ? a : b);
    final max = values.reduce((a, b) => a > b ? a : b);
    final mean = values.reduce((a, b) => a + b) / values.length;
    final uniformity = mean > 0 ? min / mean : 0.0;

    return AreaStats(min: min, max: max, mean: mean, uniformity: uniformity);
  }

  static List<List<String>> _buildTableData(
    List<MeasurementMarker> markers,
    Offset referencePoint,
    double pixelsPerMeter,
  ) {
    return markers.asMap().entries.map((entry) {
      final i = entry.key;
      final m = entry.value;
      final x = ((m.position.dx - referencePoint.dx) / pixelsPerMeter)
          .toStringAsFixed(2);
      final y = ((referencePoint.dy - m.position.dy) / pixelsPerMeter)
          .toStringAsFixed(2);

      return [
        '${i + 1}',
        m.label,
        '$x m / $y m',
        '${m.height}m',
        m.sensorValue != null ? _formatLux(m.sensorValue!) : '-',
      ];
    }).toList();
  }

  static String _translateType(String deType) {
    if (deType == 'Allgemeinbeleuchtung') return 'General Lighting';
    if (deType == 'Sicherheitsbeleuchtung') return 'Emergency Lighting';
    if (deType == 'Treppen') return 'Stairs';
    if (deType == 'Parkbauten') return 'Parking Areas';
    return deType;
  }

  static const Map<String, String> _de = {
    'project': 'Projekt',
    'surveyor': 'Prüfer',
    'date': 'Datum',
    'devices': 'Geräte',
    'measurement': 'Messung',
    'notes': 'Notizen',
    'min': 'Minimum',
    'avg': 'Mittel',
    'max': 'Maximum',
    'uni': 'Gleichmäßigkeit',
    'label': 'Bezeichnung',
    'pos': 'Position (X/Y)',
    'height': 'Höhe',
    'value': 'Wert',
  };

  static const Map<String, String> _en = {
    'project': 'Project',
    'surveyor': 'Surveyor',
    'date': 'Date',
    'devices': 'Devices',
    'measurement': 'Measurement',
    'notes': 'Notes',
    'min': 'Minimum',
    'avg': 'Average',
    'max': 'Maximum',
    'uni': 'Uniformity',
    'label': 'Label',
    'pos': 'Position (X/Y)',
    'height': 'Height',
    'value': 'Value',
  };
}

// Hilfsklasse für compute()
class _PdfParams {
  final Uint8List floorPlanBytes;
  final Uint8List? logoBytes;
  final Size pdfSize;
  final String projectName;
  final String surveyorName;
  final String projectDate;
  final String usedDevices;
  final String additionalNotes;
  final String selectedMeasurementType;
  final List<MeasurementArea> areas;
  final Offset referencePoint;
  final double pixelsPerMeter;
  final double markerSize;
  final bool isEnglish;

  _PdfParams({
    required this.floorPlanBytes,
    required this.logoBytes,
    required this.pdfSize,
    required this.projectName,
    required this.surveyorName,
    required this.projectDate,
    required this.usedDevices,
    required this.additionalNotes,
    required this.selectedMeasurementType,
    required this.areas,
    required this.referencePoint,
    required this.pixelsPerMeter,
    required this.markerSize,
    required this.isEnglish,
  });
}

class AreaStats {
  final double? min;
  final double? max;
  final double? mean;
  final double uniformity;
  AreaStats({this.min, this.max, this.mean, this.uniformity = 0.0});
  bool get hasValues => min != null && mean != null;
}
