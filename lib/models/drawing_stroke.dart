import 'package:flutter/material.dart';

enum DrawingKind {
  freehand,
  line,
  polyline,
  rectangle,
  text;

  static DrawingKind fromName(String? value) {
    return DrawingKind.values.firstWhere(
      (DrawingKind item) => item.name == value,
      orElse: () => DrawingKind.freehand,
    );
  }
}

enum DrawingBrush {
  ballpoint,
  fountain,
  marker,
  highlighter;

  static DrawingBrush fromName(String? value) {
    return DrawingBrush.values.firstWhere(
      (DrawingBrush item) => item.name == value,
      orElse: () => DrawingBrush.fountain,
    );
  }
}

class DrawingPoint {
  const DrawingPoint({
    required this.position,
    this.pressure = 0.5,
  });

  final Offset position;
  final double pressure;
}

class DrawingStroke {
  const DrawingStroke({
    required this.id,
    required this.pageNumber,
    required this.points,
    this.width = 3.0,
    this.color = const Color(0xFFE53935),
    this.opacity = 1,
    this.kind = DrawingKind.freehand,
    this.brush = DrawingBrush.fountain,
    this.text = '',
    this.fontSize = 18,
    this.textBoxWidthRatio = 0.45,
    this.rotationDegrees = 0,
  });

  final String id;
  final int pageNumber;
  final List<DrawingPoint> points;
  final double width;
  final Color color;
  final double opacity;
  final DrawingKind kind;
  final DrawingBrush brush;
  final String text;
  final double fontSize;
  final double textBoxWidthRatio;
  final double rotationDegrees;

  DrawingStroke copyWith({
    List<DrawingPoint>? points,
    double? width,
    Color? color,
    double? opacity,
    DrawingKind? kind,
    DrawingBrush? brush,
    String? text,
    double? fontSize,
    double? textBoxWidthRatio,
    double? rotationDegrees,
  }) {
    return DrawingStroke(
      id: id,
      pageNumber: pageNumber,
      points: points ?? this.points,
      width: width ?? this.width,
      color: color ?? this.color,
      opacity: opacity ?? this.opacity,
      kind: kind ?? this.kind,
      brush: brush ?? this.brush,
      text: text ?? this.text,
      fontSize: fontSize ?? this.fontSize,
      textBoxWidthRatio: textBoxWidthRatio ?? this.textBoxWidthRatio,
      rotationDegrees: rotationDegrees ?? this.rotationDegrees,
    );
  }
}
