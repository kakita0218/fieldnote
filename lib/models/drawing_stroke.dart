import 'package:flutter/material.dart';

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
  });

  final String id;
  final int pageNumber;
  final List<DrawingPoint> points;
  final double width;
  final Color color;

  DrawingStroke copyWith({
    List<DrawingPoint>? points,
  }) {
    return DrawingStroke(
      id: id,
      pageNumber: pageNumber,
      points: points ?? this.points,
      width: width,
      color: color,
    );
  }
}
