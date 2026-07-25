import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/drawing_stroke.dart';

class HandwritingLayer extends StatelessWidget {
  const HandwritingLayer({
    super.key,
    required this.strokes,
  });

  final List<DrawingStroke> strokes;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _HandwritingPainter(strokes),
        size: Size.infinite,
      ),
    );
  }
}

class _HandwritingPainter extends CustomPainter {
  const _HandwritingPainter(this.strokes);

  final List<DrawingStroke> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    for (final DrawingStroke stroke in strokes) {
      if (stroke.points.isEmpty) {
        continue;
      }

      if (stroke.points.length == 1) {
        final DrawingPoint point = stroke.points.first;
        final Offset position = Offset(
          point.position.dx * size.width,
          point.position.dy * size.height,
        );
        final double radius = _lineWidth(stroke, point.pressure) / 2;
        canvas.drawCircle(
          position,
          radius,
          Paint()
            ..color = stroke.color
            ..style = PaintingStyle.fill,
        );
        continue;
      }

      for (int index = 1; index < stroke.points.length; index++) {
        final DrawingPoint previous = stroke.points[index - 1];
        final DrawingPoint current = stroke.points[index];
        final Offset start = Offset(
          previous.position.dx * size.width,
          previous.position.dy * size.height,
        );
        final Offset end = Offset(
          current.position.dx * size.width,
          current.position.dy * size.height,
        );
        final double pressure = (previous.pressure + current.pressure) / 2;

        canvas.drawLine(
          start,
          end,
          Paint()
            ..color = stroke.color
            ..strokeWidth = _lineWidth(stroke, pressure)
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..style = PaintingStyle.stroke
            ..isAntiAlias = true,
        );
      }
    }
  }

  double _lineWidth(DrawingStroke stroke, double pressure) {
    final double safePressure = pressure.isFinite ? pressure : 0.5;
    return stroke.width * (0.55 + math.max(0.0, safePressure) * 0.9);
  }

  @override
  bool shouldRepaint(covariant _HandwritingPainter oldDelegate) {
    return oldDelegate.strokes != strokes;
  }
}
