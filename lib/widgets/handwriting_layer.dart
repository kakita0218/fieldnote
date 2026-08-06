import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/drawing_stroke.dart';

double drawingStrokeWidth(DrawingStroke stroke, double pressure) {
  final double safePressure =
      (pressure.isFinite ? pressure : 0.5).clamp(0.0, 1.0);
  return switch (stroke.brush) {
    DrawingBrush.fountain => stroke.width * (0.55 + safePressure * 0.9),
    DrawingBrush.ballpoint => stroke.width,
    DrawingBrush.marker => stroke.width * 1.1,
    DrawingBrush.highlighter => stroke.width,
  };
}

Color _drawingColor(DrawingStroke stroke) {
  final double effectiveOpacity = switch (stroke.brush) {
    DrawingBrush.highlighter => stroke.opacity.clamp(0.05, 0.55),
    _ => stroke.opacity.clamp(0.05, 1.0),
  };
  return stroke.color.withValues(
    alpha: (stroke.color.a * effectiveOpacity).clamp(0.0, 1.0),
  );
}

Rect drawingStrokeBounds(DrawingStroke stroke, Size size) {
  if (stroke.points.isEmpty) return Rect.zero;
  final Iterable<Offset> positions = stroke.points.map(
    (DrawingPoint point) => Offset(
      point.position.dx * size.width,
      point.position.dy * size.height,
    ),
  );
  double left = double.infinity;
  double top = double.infinity;
  double right = double.negativeInfinity;
  double bottom = double.negativeInfinity;
  for (final Offset position in positions) {
    left = position.dx < left ? position.dx : left;
    top = position.dy < top ? position.dy : top;
    right = position.dx > right ? position.dx : right;
    bottom = position.dy > bottom ? position.dy : bottom;
  }
  if (stroke.kind == DrawingKind.text) {
    final String measuredText = stroke.text.isEmpty ? '文字を入力' : stroke.text;
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: measuredText,
        style: TextStyle(fontSize: stroke.fontSize),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width * stroke.textBoxWidthRatio);
    right = left + painter.width;
    bottom = top + painter.height;
  } else if (stroke.kind == DrawingKind.rectangle &&
      stroke.points.length >= 2 &&
      stroke.rotationDegrees % 360 != 0) {
    final List<Offset> corners = drawingRectangleCorners(stroke, size);
    left = corners.map((Offset point) => point.dx).reduce(math.min);
    top = corners.map((Offset point) => point.dy).reduce(math.min);
    right = corners.map((Offset point) => point.dx).reduce(math.max);
    bottom = corners.map((Offset point) => point.dy).reduce(math.max);
  }
  final double padding = stroke.kind == DrawingKind.text
      ? 4
      : drawingStrokeWidth(stroke, 0.5) / 2 + 4;
  return Rect.fromLTRB(left, top, right, bottom).inflate(padding);
}

List<Offset> drawingRectangleCorners(DrawingStroke stroke, Size size) {
  if (stroke.points.length < 2) return const <Offset>[];
  final Rect rect = Rect.fromPoints(
    Offset(
      stroke.points.first.position.dx * size.width,
      stroke.points.first.position.dy * size.height,
    ),
    Offset(
      stroke.points.last.position.dx * size.width,
      stroke.points.last.position.dy * size.height,
    ),
  );
  final List<Offset> corners = <Offset>[
    rect.topLeft,
    rect.topRight,
    rect.bottomRight,
    rect.bottomLeft,
  ];
  final double radians = stroke.rotationDegrees * math.pi / 180;
  if (radians == 0) return corners;
  final double cosine = math.cos(radians);
  final double sine = math.sin(radians);
  return corners.map((Offset point) {
    final Offset delta = point - rect.center;
    return rect.center +
        Offset(
          delta.dx * cosine - delta.dy * sine,
          delta.dx * sine + delta.dy * cosine,
        );
  }).toList(growable: false);
}

Offset drawingRectangleRotationHandle(DrawingStroke stroke, Size size) {
  final List<Offset> corners = drawingRectangleCorners(stroke, size);
  if (corners.length < 4) return Offset.zero;
  final Offset topCenter = Offset.lerp(corners[0], corners[1], 0.5)!;
  final Offset center = Offset.lerp(corners[0], corners[2], 0.5)!;
  final Offset outward = topCenter - center;
  if (outward.distance == 0) return topCenter;
  return topCenter + outward / outward.distance * 28;
}

/// Paints normalized handwriting in the same way on screen and during PDF
/// export. A one-point stroke is intentionally rendered as a dot.
void paintDrawingStrokes(
  Canvas canvas,
  Size size,
  Iterable<DrawingStroke> strokes, {
  double widthScale = 1,
  String? selectedStrokeId,
}) {
  for (final DrawingStroke stroke in strokes) {
    if (stroke.points.isEmpty) {
      continue;
    }

    final Color color = _drawingColor(stroke);

    if (stroke.kind == DrawingKind.text) {
      final DrawingPoint anchor = stroke.points.first;
      final bool showPlaceholder =
          stroke.text.isEmpty && selectedStrokeId == stroke.id;
      if (stroke.text.isNotEmpty || showPlaceholder) {
        final TextPainter painter = TextPainter(
          text: TextSpan(
            text: showPlaceholder ? '文字を入力' : stroke.text,
            style: TextStyle(
              color: showPlaceholder
                  ? color.withValues(alpha: color.a * 0.55)
                  : color,
              fontSize: stroke.fontSize * widthScale,
              fontWeight: FontWeight.w600,
              fontStyle: showPlaceholder ? FontStyle.italic : FontStyle.normal,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: size.width * stroke.textBoxWidthRatio);
        painter.paint(
          canvas,
          Offset(anchor.position.dx * size.width,
              anchor.position.dy * size.height),
        );
      }
    } else if (stroke.kind == DrawingKind.rectangle &&
        stroke.points.length >= 2) {
      final Offset start = Offset(
        stroke.points.first.position.dx * size.width,
        stroke.points.first.position.dy * size.height,
      );
      final Offset end = Offset(
        stroke.points.last.position.dx * size.width,
        stroke.points.last.position.dy * size.height,
      );
      final Rect rect = Rect.fromPoints(start, end);
      canvas.save();
      canvas.translate(rect.center.dx, rect.center.dy);
      canvas.rotate(stroke.rotationDegrees * math.pi / 180);
      canvas.translate(-rect.center.dx, -rect.center.dy);
      canvas.drawRect(
        rect,
        Paint()
          ..color = color
          ..strokeWidth = stroke.width * widthScale
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true,
      );
      canvas.restore();
    } else if (stroke.kind == DrawingKind.line && stroke.points.length >= 2) {
      final DrawingPoint start = stroke.points.first;
      final DrawingPoint end = stroke.points.last;
      canvas.drawLine(
        Offset(start.position.dx * size.width, start.position.dy * size.height),
        Offset(end.position.dx * size.width, end.position.dy * size.height),
        Paint()
          ..color = color
          ..strokeWidth = stroke.width * widthScale
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true,
      );
    } else if (stroke.points.length == 1) {
      final DrawingPoint point = stroke.points.first;
      final Offset position = Offset(
        point.position.dx * size.width,
        point.position.dy * size.height,
      );
      final double radius =
          drawingStrokeWidth(stroke, point.pressure) * widthScale / 2;
      canvas.drawCircle(
        position,
        radius,
        Paint()
          ..color = color
          ..style = PaintingStyle.fill
          ..isAntiAlias = true,
      );
    } else {
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
            ..color = color
            ..strokeWidth = drawingStrokeWidth(stroke, pressure) * widthScale
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..style = PaintingStyle.stroke
            ..isAntiAlias = true,
        );
      }
    }

    if (selectedStrokeId == stroke.id) {
      _paintSelection(canvas, size, stroke);
    }
  }
}

void _paintSelection(Canvas canvas, Size size, DrawingStroke stroke) {
  const Color selectionColor = Color(0xFF42A5F5);
  final Paint outline = Paint()
    ..color = selectionColor
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5;
  final Paint handleFill = Paint()
    ..color = Colors.white
    ..style = PaintingStyle.fill;
  final Paint handleEdge = Paint()
    ..color = selectionColor
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2;

  void drawHandle(Offset point, {double radius = 6}) {
    canvas.drawCircle(point, radius, handleFill);
    canvas.drawCircle(point, radius, handleEdge);
  }

  if (stroke.kind == DrawingKind.rectangle && stroke.points.length >= 2) {
    final List<Offset> corners = drawingRectangleCorners(stroke, size);
    final Path path = Path()..moveTo(corners.first.dx, corners.first.dy);
    for (final Offset corner in corners.skip(1)) {
      path.lineTo(corner.dx, corner.dy);
    }
    path.close();
    canvas.drawPath(path, outline);
    for (final Offset corner in corners) {
      drawHandle(corner);
    }
    final Offset topCenter = Offset.lerp(corners[0], corners[1], 0.5)!;
    final Offset rotationHandle = drawingRectangleRotationHandle(stroke, size);
    canvas.drawLine(topCenter, rotationHandle, outline);
    drawHandle(rotationHandle, radius: 7);
    return;
  }

  if (stroke.kind == DrawingKind.line || stroke.kind == DrawingKind.polyline) {
    final List<Offset> points = stroke.points
        .map(
          (DrawingPoint point) => Offset(
            point.position.dx * size.width,
            point.position.dy * size.height,
          ),
        )
        .toList(growable: false);
    for (final Offset point in points) {
      drawHandle(point);
    }
    return;
  }

  final Rect bounds = drawingStrokeBounds(stroke, size);
  if (bounds.isEmpty) return;
  canvas.drawRect(bounds, outline);
  if (stroke.kind == DrawingKind.text) {
    drawHandle(bounds.topLeft);
    drawHandle(bounds.topRight);
    drawHandle(bounds.bottomRight);
    drawHandle(bounds.bottomLeft);
  }
}

class HandwritingLayer extends StatelessWidget {
  const HandwritingLayer({
    super.key,
    required this.strokes,
    this.selectedStrokeId,
  });

  final List<DrawingStroke> strokes;
  final String? selectedStrokeId;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _HandwritingPainter(strokes, selectedStrokeId),
        size: Size.infinite,
      ),
    );
  }
}

class _HandwritingPainter extends CustomPainter {
  const _HandwritingPainter(this.strokes, this.selectedStrokeId);

  final List<DrawingStroke> strokes;
  final String? selectedStrokeId;

  @override
  void paint(Canvas canvas, Size size) {
    paintDrawingStrokes(
      canvas,
      size,
      strokes,
      selectedStrokeId: selectedStrokeId,
    );
  }

  @override
  bool shouldRepaint(covariant _HandwritingPainter oldDelegate) {
    return oldDelegate.strokes != strokes ||
        oldDelegate.selectedStrokeId != selectedStrokeId;
  }
}
