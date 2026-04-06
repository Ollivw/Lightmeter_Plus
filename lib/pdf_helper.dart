import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'models/measurement_models.dart';

class PdfHelper {
  static Future<void> exportToPdf({
    required Uint8List pdfBytes,
    required Uint8List? logoBytes,
    required Size pdfSize,
    required String projectName,
    required String surveyorName,
    required String projectDate,
    required String usedDevices,
    required String additionalNotes,
    required List<MeasurementArea> areas,
    required Offset referencePoint,
    required double pixelsPerMeter,
    required double markerSize,
  }) async {
    final pdf = pw.Document();
    final image = pw.MemoryImage(pdfBytes);
    final pw.MemoryImage? logoImage = logoBytes != null
        ? pw.MemoryImage(logoBytes)
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

    // Seite 1: Übersicht mit Grundriss
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        orientation: pdfSize.width > pdfSize.height
            ? pw.PageOrientation.landscape
            : pw.PageOrientation.portrait,
        build: (pw.Context context) {
          return pw.FittedBox(
            fit: pw.BoxFit.contain,
            child: pw.SizedBox(
              width: pdfSize.width,
              height: pdfSize.height,
              child: pw.Stack(
                children: [
                  pw.Image(image),
                  if (referencePoint != Offset.zero)
                    pw.Positioned(
                      left: referencePoint.dx - (markerSize / 2),
                      top: referencePoint.dy - (markerSize / 2),
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
                    ),
                  ...areas.expand(
                    (area) => area.markers.asMap().entries.map((entry) {
                      final marker = entry.value;
                      return pw.Positioned(
                        left: marker.position.dx - (markerSize * 4),
                        bottom:
                            pdfSize.height -
                            marker.position.dy -
                            (markerSize * 0.25),
                        child: pw.SizedBox(
                          width: markerSize * 8,
                          child: pw.Column(
                            mainAxisSize: pw.MainAxisSize.min,
                            crossAxisAlignment: pw.CrossAxisAlignment.center,
                            children: [
                              pw.Text(
                                area.name,
                                style: pw.TextStyle(
                                  fontSize: markerSize * 0.3,
                                  color: PdfColors.grey700,
                                ),
                              ),
                              pw.Text(
                                marker.label.isNotEmpty
                                    ? marker.label
                                    : '${entry.key + 1}',
                                style: pw.TextStyle(
                                  fontSize: markerSize * 0.5,
                                  color: PdfColors.red,
                                  fontWeight: pw.FontWeight.bold,
                                ),
                              ),
                              if (marker.sensorValue != null)
                                pw.Text(
                                  marker.sensorValue! > 20
                                      ? '${marker.sensorValue!.round()} lx'
                                      : (marker.sensorValue! ==
                                                marker.sensorValue!
                                                    .roundToDouble()
                                            ? '${marker.sensorValue!.toInt()} lx'
                                            : '${marker.sensorValue!.toStringAsFixed(1)} lx'),
                                  style: pw.TextStyle(
                                    fontSize: markerSize * 0.5,
                                    color: PdfColors.green,
                                  ),
                                ),
                              pw.Container(
                                width: markerSize * 0.5,
                                height: markerSize * 0.5,
                                decoration: const pw.BoxDecoration(
                                  color: PdfColors.red,
                                  shape: pw.BoxShape.circle,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    // Detailseiten pro Bereich
    for (var area in areas) {
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

      final List<List<String>> tableData = [];
      for (var i = 0; i < area.markers.length; i++) {
        final m = area.markers[i];
        final x = ((m.position.dx - referencePoint.dx) / pixelsPerMeter)
            .toStringAsFixed(2);
        final y = ((referencePoint.dy - m.position.dy) / pixelsPerMeter)
            .toStringAsFixed(2);
        final formattedValue = m.sensorValue != null
            ? (m.sensorValue! > 20
                  ? '${m.sensorValue!.round()} lx'
                  : (m.sensorValue! == m.sensorValue!.roundToDouble()
                        ? '${m.sensorValue!.toInt()} lx'
                        : '${m.sensorValue!.toStringAsFixed(1)} lx'))
            : '-';
        tableData.add([
          '${i + 1}',
          m.label,
          '${x}m / ${y}m',
          '${m.height}m',
          formattedValue,
        ]);
        if (i % 50 == 0) await Future.delayed(Duration.zero);
      }

      const int chunkSize = 40;
      final List<List<List<String>>> dataChunks = [];
      for (var i = 0; i < tableData.length; i += chunkSize) {
        dataChunks.add(
          tableData.sublist(
            i,
            i + chunkSize > tableData.length ? tableData.length : i + chunkSize,
          ),
        );
      }

      await Future.delayed(Duration.zero);
      pdf.addPage(
        pw.MultiPage(
          build: (pw.Context context) => [
            buildPdfHeader(),
            pw.Text(
              'Messbericht - Bereich: ${area.name}',
              style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 20),
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
                        'Projekt: ${projectName.isEmpty ? "Unbenannt" : projectName}',
                        style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                      ),
                      pw.Text('Datum/Zeit: $projectDate'),
                    ],
                  ),
                  pw.Divider(color: PdfColors.grey300),
                  pw.Text(
                    'Prüfer: ${surveyorName.isEmpty ? "Nicht angegeben" : surveyorName}',
                  ),
                  pw.Text(
                    'Geräte: ${usedDevices.isEmpty ? "Nicht angegeben" : usedDevices}',
                  ),
                  if (additionalNotes.isNotEmpty)
                    pw.Padding(
                      padding: const pw.EdgeInsets.only(top: 4),
                      child: pw.Text(
                        'Notizen: $additionalNotes',
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
            ...dataChunks.asMap().entries.map(
              (entry) => pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 2),
                child: pw.Table.fromTextArray(
                  border: null,
                  columnWidths: {
                    0: const pw.FixedColumnWidth(25),
                    1: const pw.FlexColumnWidth(3),
                    2: const pw.FlexColumnWidth(2),
                    3: const pw.FixedColumnWidth(50),
                    4: const pw.FixedColumnWidth(70),
                  },
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
                  cellHeight: 25,
                  cellAlignments: {
                    0: pw.Alignment.centerLeft,
                    1: pw.Alignment.centerLeft,
                    2: pw.Alignment.centerLeft,
                    3: pw.Alignment.centerLeft,
                    4: pw.Alignment.centerRight,
                  },
                  headers: entry.key == 0
                      ? ['#', 'Bezeichnung', 'Position (X/Y)', 'Höhe', 'Wert']
                      : null,
                  data: entry.value,
                ),
              ),
            ),
          ],
        ),
      );
    }

    await Future.delayed(Duration.zero);
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdf.save(),
    );
  }
}
