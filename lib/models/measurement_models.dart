import 'package:flutter/material.dart';

class MeasurementArea {
  String name;
  final List<MeasurementMarker> markers;

  MeasurementArea({required this.name, List<MeasurementMarker>? markers})
    : markers = markers ?? [];

  Map<String, dynamic> toJson() => {
    'name': name,
    'markers': markers.map((m) => m.toJson()).toList(),
  };

  factory MeasurementArea.fromJson(Map<String, dynamic> json) =>
      MeasurementArea(
        name: json['name'] ?? 'Unbenannter Bereich',
        markers:
            (json['markers'] as List?)
                ?.map((m) => MeasurementMarker.fromJson(m))
                .toList() ??
            [],
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
        label: json['label'] ?? '',
        height: (json['height'] as num?)?.toDouble() ?? 0.8,
        sensorValue: json['sensorValue'] != null
            ? (json['sensorValue'] as num).toDouble()
            : null,
      );
}
