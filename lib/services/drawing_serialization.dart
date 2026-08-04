import 'package:flutter/material.dart';

import '../models/drawing_stroke.dart';

Map<String, dynamic> serializeDrawingStroke(DrawingStroke stroke) {
  return <String, dynamic>{
    'id': stroke.id,
    'pageNumber': stroke.pageNumber,
    'width': stroke.width,
    'color': stroke.color.toARGB32(),
    'opacity': stroke.opacity,
    'kind': stroke.kind.name,
    'brush': stroke.brush.name,
    if (stroke.text.isNotEmpty) 'text': stroke.text,
    if (stroke.kind == DrawingKind.text) 'fontSize': stroke.fontSize,
    'points': stroke.points
        .map(
          (DrawingPoint point) => <String, dynamic>{
            'x': point.position.dx,
            'y': point.position.dy,
            'pressure': point.pressure,
          },
        )
        .toList(growable: false),
  };
}

DrawingStroke? deserializeDrawingStroke(
  dynamic raw, {
  int defaultPageNumber = 0,
}) {
  if (raw is! Map) return null;
  final Map<String, dynamic> map = raw.map<String, dynamic>(
    (dynamic key, dynamic value) => MapEntry<String, dynamic>(
      key.toString(),
      value,
    ),
  );
  final String id = map['id']?.toString() ?? '';
  if (id.isEmpty) return null;
  final List<DrawingPoint> points = <DrawingPoint>[];
  for (final dynamic rawPoint in map['points'] as List? ?? const <dynamic>[]) {
    if (rawPoint is! Map) continue;
    final num? x = rawPoint['x'] as num?;
    final num? y = rawPoint['y'] as num?;
    if (x == null || y == null) continue;
    points.add(
      DrawingPoint(
        position: Offset(
          x.toDouble().clamp(0.0, 1.0),
          y.toDouble().clamp(0.0, 1.0),
        ),
        pressure:
            ((rawPoint['pressure'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 1.0),
      ),
    );
  }
  if (points.isEmpty) return null;
  return DrawingStroke(
    id: id,
    pageNumber: (map['pageNumber'] as num?)?.toInt() ?? defaultPageNumber,
    points: points,
    width: ((map['width'] as num?)?.toDouble() ?? 3).clamp(0.5, 120),
    color: Color((map['color'] as num?)?.toInt() ?? 0xFFE53935),
    opacity: ((map['opacity'] as num?)?.toDouble() ?? 1).clamp(0.05, 1.0),
    kind: DrawingKind.fromName(map['kind']?.toString()),
    brush: DrawingBrush.fromName(map['brush']?.toString()),
    text: map['text']?.toString() ?? '',
    fontSize: ((map['fontSize'] as num?)?.toDouble() ?? 18).clamp(8, 96),
  );
}
