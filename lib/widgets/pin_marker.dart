import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/pin_data.dart';

class PinMarker extends StatelessWidget {
  const PinMarker({
    super.key,
    required this.pin,
    required this.selected,
    required this.awaitingDirection,
    this.onTap,
    this.onDirectionChanged,
    this.onDirectionChangeStart,
    this.onDirectionChangeEnd,
    this.onDirectionChangeCancel,
    this.onMoveStart,
    this.onMoveUpdate,
    this.onMoveEnd,
    this.onMoveCancel,
  });

  /// The visual is roughly half the previous marker size. The transparent
  /// canvas keeps the anchor stable, while hit testing is limited to the
  /// visible circular badge itself.
  static const double markerWidth = 48;
  static const double markerHeight = 56;
  static const double markerCenterY = 24;
  static const double normalCircleSize = 24;
  static const double selectedCircleSize = 36;

  final PinData pin;
  final bool selected;
  final bool awaitingDirection;
  final VoidCallback? onTap;
  final ValueChanged<double>? onDirectionChanged;
  final VoidCallback? onDirectionChangeStart;
  final VoidCallback? onDirectionChangeEnd;
  final VoidCallback? onDirectionChangeCancel;
  final ValueChanged<Offset>? onMoveStart;
  final ValueChanged<Offset>? onMoveUpdate;
  final ValueChanged<Offset>? onMoveEnd;
  final VoidCallback? onMoveCancel;

  double get _circleSize =>
      (selected || awaitingDirection ? selectedCircleSize : normalCircleSize) *
      pin.sizeScale.clamp(1 / 3, 1);

  double _directionFromCirclePosition(
    Offset localPosition,
    double gestureSize,
  ) {
    final double half = gestureSize / 2;
    final Offset vector = localPosition - Offset(half, half);
    final double radians = math.atan2(vector.dx, -vector.dy);
    return (radians * 180 / math.pi + 360) % 360;
  }

  @override
  Widget build(BuildContext context) {
    final double circleSize = _circleSize;
    final double gestureSize = math.max(circleSize, 44);

    return Semantics(
      container: true,
      button: onTap != null,
      enabled: onTap != null,
      selected: selected,
      label: 'ピン ${pin.number}',
      value: <String>[
        if (pin.photoCount > 0) '写真${pin.photoCount}枚',
        if (awaitingDirection) '方向を指定中',
      ].join('、'),
      hint: onDirectionChanged != null
          ? 'タップして詳細を開く。ドラッグして方向を変更。長押しして移動'
          : onTap != null
              ? 'タップして詳細を開く'
              : null,
      excludeSemantics: true,
      child: SizedBox(
        width: markerWidth,
        height: markerHeight,
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _PinMarkerPainter(
                    number: pin.number,
                    directionDegrees: pin.directionDegrees,
                    color: Color(pin.colorValue),
                    opacity: pin.opacity,
                    selected: selected,
                    awaitingDirection: awaitingDirection,
                    hasPhoto: pin.photoCount > 0,
                    sizeScale: pin.sizeScale,
                    showsDirection: pin.showsDirection,
                  ),
                ),
              ),
            ),
            Positioned(
              left: (markerWidth - gestureSize) / 2,
              top: markerCenterY - gestureSize / 2,
              width: gestureSize,
              height: gestureSize,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                onPanStart: onDirectionChanged == null
                    ? null
                    : (DragStartDetails details) {
                        onDirectionChangeStart?.call();
                        onDirectionChanged!(
                          _directionFromCirclePosition(
                            details.localPosition,
                            gestureSize,
                          ),
                        );
                      },
                onPanUpdate: onDirectionChanged == null
                    ? null
                    : (DragUpdateDetails details) {
                        onDirectionChanged!(
                          _directionFromCirclePosition(
                            details.localPosition,
                            gestureSize,
                          ),
                        );
                      },
                onPanEnd: onDirectionChanged == null
                    ? null
                    : (_) => onDirectionChangeEnd?.call(),
                onPanCancel: onDirectionChanged == null
                    ? null
                    : () => onDirectionChangeCancel?.call(),
                onLongPressStart: onMoveStart == null
                    ? null
                    : (LongPressStartDetails details) {
                        onMoveStart!(details.globalPosition);
                      },
                onLongPressMoveUpdate: onMoveUpdate == null
                    ? null
                    : (LongPressMoveUpdateDetails details) {
                        onMoveUpdate!(details.globalPosition);
                      },
                onLongPressEnd: onMoveEnd == null
                    ? null
                    : (LongPressEndDetails details) {
                        onMoveEnd!(details.globalPosition);
                      },
                onLongPressCancel: onMoveCancel,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PinMarkerPainter extends CustomPainter {
  const _PinMarkerPainter({
    required this.number,
    required this.directionDegrees,
    required this.color,
    required this.opacity,
    required this.selected,
    required this.awaitingDirection,
    required this.hasPhoto,
    required this.sizeScale,
    required this.showsDirection,
  });

  final int number;
  final double directionDegrees;
  final Color color;
  final double opacity;
  final bool selected;
  final bool awaitingDirection;
  final bool hasPhoto;
  final double sizeScale;
  final bool showsDirection;

  bool get _isYellow => color.computeLuminance() > 0.62;

  @override
  void paint(Canvas canvas, Size size) {
    final bool emphasized = selected || awaitingDirection;
    final double scale = sizeScale.clamp(1 / 3, 1);
    final double diameter = (emphasized
            ? PinMarker.selectedCircleSize
            : PinMarker.normalCircleSize) *
        scale;
    final double radius = diameter / 2;
    final Offset center = Offset(size.width / 2, PinMarker.markerCenterY);
    final double safeOpacity = opacity.clamp(0.1, 1.0);
    final Color markerColor = color.withValues(
      alpha: (color.a * safeOpacity).clamp(0.0, 1.0),
    );
    final Color textColor = (_isYellow ? const Color(0xFF10151C) : Colors.white)
        .withValues(alpha: safeOpacity);
    final Color edgeColor = (_isYellow
            ? const Color(0xFF3B3420)
            : Colors.white.withValues(alpha: 0.96))
        .withValues(alpha: safeOpacity);

    if (emphasized) {
      canvas.drawCircle(
        center,
        radius + 7,
        Paint()
          ..color = const Color(0xFF42A5FF).withValues(
            alpha: awaitingDirection ? 0.38 : 0.26,
          )
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
      );
    }

    if (hasPhoto) {
      canvas.drawCircle(
        center,
        radius + 3.5 * scale,
        Paint()
          ..color = const Color(0xFF49B7FF).withValues(alpha: safeOpacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1, 2.2 * scale),
      );
    }

    if (showsDirection || awaitingDirection) {
      final double angle = directionDegrees * math.pi / 180;
      final double arrowDistance = radius + 5 * scale;
      final Offset arrowCenter =
          center + Offset(math.sin(angle), -math.cos(angle)) * arrowDistance;
      final Offset forward = Offset(math.sin(angle), -math.cos(angle));
      final Offset side = Offset(math.cos(angle), math.sin(angle));
      final double arrowLength = (emphasized ? 8 : 6) * scale;
      final double arrowHalfWidth = (emphasized ? 4.5 : 3.5) * scale;
      final Offset tip = arrowCenter + forward * (arrowLength / 2);
      final Offset baseCenter = arrowCenter - forward * (arrowLength / 2);
      final Path arrow = Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(
          baseCenter.dx + side.dx * arrowHalfWidth,
          baseCenter.dy + side.dy * arrowHalfWidth,
        )
        ..lineTo(
          baseCenter.dx - side.dx * arrowHalfWidth,
          baseCenter.dy - side.dy * arrowHalfWidth,
        )
        ..close();
      canvas.drawPath(
        arrow,
        Paint()
          ..color = edgeColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1, 2.6 * scale)
          ..strokeJoin = StrokeJoin.round,
      );
      canvas.drawPath(arrow, Paint()..color = markerColor);
    }

    canvas.drawCircle(center, radius, Paint()..color = markerColor);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = edgeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, (emphasized ? 2.1 : 1.6) * scale),
    );

    final String label = number.toString();
    final double baseFontSize = (emphasized ? 16 : 11) * scale;
    final double fontSize = math.max(
        4, label.length >= 3 ? baseFontSize - 2 * scale : baseFontSize);
    final TextPainter textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: textColor,
          fontSize: fontSize,
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout(maxWidth: diameter - 4);
    textPainter.paint(
      canvas,
      center - Offset(textPainter.width / 2, textPainter.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant _PinMarkerPainter oldDelegate) {
    return oldDelegate.number != number ||
        oldDelegate.directionDegrees != directionDegrees ||
        oldDelegate.color != color ||
        oldDelegate.opacity != opacity ||
        oldDelegate.selected != selected ||
        oldDelegate.awaitingDirection != awaitingDirection ||
        oldDelegate.hasPhoto != hasPhoto ||
        oldDelegate.sizeScale != sizeScale ||
        oldDelegate.showsDirection != showsDirection;
  }
}
