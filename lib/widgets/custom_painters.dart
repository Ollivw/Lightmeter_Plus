import 'package:flutter/material.dart';

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
      ..color = Colors.green.withValues(alpha: 0.5)
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
  bool shouldRepaint(covariant GridPainter oldDelegate) =>
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
  final Offset referencePoint;
  final bool isSettingReferencePoint;
  final TransformationController controller;

  MeasurementPainter({
    this.calibrationStart,
    this.calibrationEnd,
    this.currentMousePosition,
    required this.isCalibrating,
    required this.referencePoint,
    required this.isSettingReferencePoint,
    required this.controller,
  }) : super(repaint: controller);

  @override
  void paint(Canvas canvas, Size size) {
    final scale = controller.value.getMaxScaleOnAxis();

    if (referencePoint != Offset.zero || isSettingReferencePoint) {
      final refPaint = Paint()
        ..color = Colors.blue
        ..strokeWidth = 2 / scale
        ..style = PaintingStyle.stroke;

      double crossSize = 15 / scale;
      canvas.drawLine(
        referencePoint - Offset(crossSize, 0),
        referencePoint + Offset(crossSize, 0),
        refPaint,
      );
      canvas.drawLine(
        referencePoint - Offset(0, crossSize),
        referencePoint + Offset(0, crossSize),
        refPaint,
      );

      final textPainter = TextPainter(
        text: TextSpan(
          text: 'REF',
          style: TextStyle(
            color: Colors.blue,
            fontWeight: FontWeight.bold,
            fontSize: 12 / scale,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(canvas, referencePoint + Offset(5 / scale, 5 / scale));
    }

    if (!isCalibrating) return;

    final start = calibrationStart;
    if (start != null) {
      final Offset end = calibrationEnd ?? currentMousePosition ?? start;
      final paint = Paint()
        ..color = Colors.orange
        ..strokeWidth = 3.0 / scale
        ..style = PaintingStyle.stroke;

      canvas.drawLine(start, end, paint);
      paint.style = PaintingStyle.fill;
      canvas.drawCircle(start, 6.0 / scale, paint);
      canvas.drawCircle(end, 6.0 / scale, paint);
    }
  }

  @override
  bool shouldRepaint(covariant MeasurementPainter oldDelegate) => true;
}
