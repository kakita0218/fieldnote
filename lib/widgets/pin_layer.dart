import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';

import '../models/pin_data.dart';
import 'pin_marker.dart';

class PinLayer extends StatelessWidget {
  const PinLayer({
    super.key,
    required this.controller,
    required this.currentPage,
    required this.pins,
    required this.pinModeEnabled,
    required this.selectedPinId,
    required this.pendingDirectionPinId,
    required this.onAddPin,
    required this.onPinTap,
    required this.onDirectionChanged,
  });

  final PdfControllerPinch controller;
  final int currentPage;
  final List<PinData> pins;
  final bool pinModeEnabled;
  final String? selectedPinId;
  final String? pendingDirectionPinId;
  final ValueChanged<Offset> onAddPin;
  final ValueChanged<PinData> onPinTap;
  final void Function(PinData pin, double directionDegrees)
      onDirectionChanged;

  double _directionFromPoints(Offset from, Offset to) {
    final Offset vector = to - from;

    // 0°は上、90°は右、180°は下、270°は左。
    final double radians = math.atan2(vector.dx, -vector.dy);
    return (radians * 180 / math.pi + 360) % 360;
  }

  Rect? _pageRect() {
    try {
      return controller.getPageRect(currentPage);
    } catch (_) {
      return null;
    }
  }

  Offset? _pinViewportPosition(PinData pin, Rect pageRect) {
    final Offset scenePoint = Offset(
      pageRect.left + pin.xRatio * pageRect.width,
      pageRect.top + pin.yRatio * pageRect.height,
    );

    return MatrixUtils.transformPoint(controller.value, scenePoint);
  }

  Offset? _normalizedPositionFromViewport(
    Offset viewportPosition,
    Rect pageRect,
  ) {
    final Offset scenePosition;

    try {
      scenePosition = controller.toScene(viewportPosition);
    } catch (_) {
      return null;
    }

    if (!pageRect.contains(scenePosition)) {
      return null;
    }

    final double x =
        ((scenePosition.dx - pageRect.left) / pageRect.width).clamp(0.0, 1.0);
    final double y =
        ((scenePosition.dy - pageRect.top) / pageRect.height).clamp(0.0, 1.0);

    return Offset(x, y);
  }

  Widget _buildPin(PinData pin, Rect pageRect) {
    final Offset? position = _pinViewportPosition(pin, pageRect);
    if (position == null) {
      return const SizedBox.shrink();
    }

    return Positioned(
      left: position.dx - PinMarker.markerWidth / 2,
      top: position.dy - PinMarker.markerCenterY,
      child: PinMarker(
        key: ValueKey<String>(pin.id),
        pin: pin,
        selected: pin.id == selectedPinId,
        awaitingDirection: pin.id == pendingDirectionPinId,
        onTap: () {
          onPinTap(pin);
        },
        onDirectionChanged: (direction) {
          onDirectionChanged(pin, direction);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final Rect? pageRect = _pageRect();

        if (pageRect == null || pageRect.width <= 0 || pageRect.height <= 0) {
          return const SizedBox.expand();
        }

        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapUp: pinModeEnabled
              ? (details) {
                  final Offset local = details.localPosition;

                  PinData? pendingPin;
                  final String? pendingId = pendingDirectionPinId;

                  if (pendingId != null) {
                    for (final PinData pin in pins) {
                      if (pin.id == pendingId) {
                        pendingPin = pin;
                        break;
                      }
                    }
                  }

                  if (pendingPin != null) {
                    final Offset? pinCenter =
                        _pinViewportPosition(pendingPin, pageRect);

                    if (pinCenter == null) {
                      return;
                    }

                    final double direction =
                        _directionFromPoints(pinCenter, local);
                    onDirectionChanged(pendingPin, direction);
                    return;
                  }

                  final Offset? normalized =
                      _normalizedPositionFromViewport(local, pageRect);

                  if (normalized != null) {
                    onAddPin(normalized);
                  }
                }
              : null,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (final PinData pin in pins) _buildPin(pin, pageRect),
            ],
          ),
        );
      },
    );
  }
}
