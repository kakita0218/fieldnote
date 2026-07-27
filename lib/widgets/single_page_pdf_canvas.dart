import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/drawing_stroke.dart';
import '../models/pin_data.dart';
import 'handwriting_layer.dart';
import 'touch_interactive_viewer.dart';
import 'pin_marker.dart';

class SinglePagePdfCanvas extends StatefulWidget {
  const SinglePagePdfCanvas({
    super.key,
    required this.imageBytes,
    required this.pageAspectRatio,
    required this.transformationController,
    required this.pins,
    required this.strokes,
    required this.pinModeEnabled,
    required this.penModeEnabled,
    required this.selectedPinId,
    required this.pendingDirectionPinId,
    required this.onAddPin,
    required this.onPinTap,
    required this.onDirectionChanged,
    required this.onPinMoveStart,
    required this.onPinMoveUpdate,
    required this.onPinMoveEnd,
    required this.onPinMoveCancel,
    required this.onStrokeStart,
    required this.onStrokeUpdate,
    required this.onStrokeEnd,
  });

  final Uint8List imageBytes;
  final double pageAspectRatio;
  final TransformationController transformationController;
  final List<PinData> pins;
  final List<DrawingStroke> strokes;
  final bool pinModeEnabled;
  final bool penModeEnabled;
  final String? selectedPinId;
  final String? pendingDirectionPinId;
  final ValueChanged<Offset> onAddPin;
  final ValueChanged<PinData> onPinTap;
  final void Function(PinData pin, double directionDegrees) onDirectionChanged;
  final ValueChanged<PinData> onPinMoveStart;
  final void Function(PinData pin, Offset normalizedPosition) onPinMoveUpdate;
  final void Function(PinData pin, Offset normalizedPosition) onPinMoveEnd;
  final ValueChanged<PinData> onPinMoveCancel;
  final void Function(Offset normalizedPosition, double pressure) onStrokeStart;
  final void Function(Offset normalizedPosition, double pressure)
      onStrokeUpdate;
  final VoidCallback onStrokeEnd;

  @override
  State<SinglePagePdfCanvas> createState() => _SinglePagePdfCanvasState();
}

class _SinglePagePdfCanvasState extends State<SinglePagePdfCanvas> {
  final GlobalKey _pageKey = GlobalKey();
  int? _activeStylusPointer;
  String? _movingPinId;

  @override
  void didUpdateWidget(covariant SinglePagePdfCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.penModeEnabled && !widget.penModeEnabled) {
      _activeStylusPointer = null;
    }
  }

  double _directionFromPoints(Offset from, Offset to) {
    final Offset vector = to - from;
    final double radians = math.atan2(vector.dx, -vector.dy);
    return (radians * 180 / math.pi + 360) % 360;
  }

  Offset _normalize(Offset local, double width, double height) {
    return Offset(
      (local.dx / width).clamp(0.0, 1.0),
      (local.dy / height).clamp(0.0, 1.0),
    );
  }

  double _pressure(PointerEvent event) {
    final double range = event.pressureMax - event.pressureMin;
    if (range <= 0) {
      return 0.5;
    }
    return ((event.pressure - event.pressureMin) / range)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  Offset? _normalizedFromGlobal(Offset globalPosition) {
    final BuildContext? pageContext = _pageKey.currentContext;
    final RenderObject? renderObject = pageContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;
    final Offset local = renderObject.globalToLocal(globalPosition);
    return _normalize(local, renderObject.size.width, renderObject.size.height);
  }

  void _startMovingPin(PinData pin) {
    setState(() => _movingPinId = pin.id);
    widget.onPinMoveStart(pin);
  }

  void _updateMovingPin(PinData pin, Offset globalPosition) {
    if (_movingPinId != pin.id) return;
    final Offset? normalized = _normalizedFromGlobal(globalPosition);
    if (normalized != null) widget.onPinMoveUpdate(pin, normalized);
  }

  void _finishMovingPin(PinData pin, Offset globalPosition) {
    if (_movingPinId != pin.id) return;
    final Offset? normalized = _normalizedFromGlobal(globalPosition);
    setState(() => _movingPinId = null);
    if (normalized == null) {
      widget.onPinMoveCancel(pin);
    } else {
      widget.onPinMoveEnd(pin, normalized);
    }
  }

  void _cancelMovingPin(PinData pin) {
    if (_movingPinId != pin.id) return;
    setState(() => _movingPinId = null);
    widget.onPinMoveCancel(pin);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth <= 0 ||
            constraints.maxHeight <= 0 ||
            widget.pageAspectRatio <= 0) {
          return const SizedBox.shrink();
        }

        double pageWidth = constraints.maxWidth;
        double pageHeight = pageWidth / widget.pageAspectRatio;

        if (pageHeight > constraints.maxHeight) {
          pageHeight = constraints.maxHeight;
          pageWidth = pageHeight * widget.pageAspectRatio;
        }

        PinData? pendingPin;
        final String? pendingId = widget.pendingDirectionPinId;
        if (pendingId != null) {
          for (final PinData pin in widget.pins) {
            if (pin.id == pendingId) {
              pendingPin = pin;
              break;
            }
          }
        }

        return TouchInteractiveViewer(
          transformationController: widget.transformationController,
          interactionEnabled:
              _activeStylusPointer == null && _movingPinId == null,
          minScale: 1,
          maxScale: 10,
          child: Center(
            child: SizedBox(
              key: _pageKey,
              width: pageWidth,
              height: pageHeight,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: widget.penModeEnabled
                    ? (event) {
                        if (event.kind != PointerDeviceKind.stylus &&
                            event.kind != PointerDeviceKind.invertedStylus) {
                          return;
                        }
                        // Ignore duplicate/overlapping pointer sequences. This
                        // prevents fast successive strokes from being joined.
                        if (_activeStylusPointer != null) return;
                        setState(() {
                          _activeStylusPointer = event.pointer;
                        });
                        widget.onStrokeStart(
                          _normalize(
                              event.localPosition, pageWidth, pageHeight),
                          _pressure(event),
                        );
                      }
                    : null,
                onPointerMove: widget.penModeEnabled
                    ? (event) {
                        if (event.pointer != _activeStylusPointer) return;
                        widget.onStrokeUpdate(
                          _normalize(
                              event.localPosition, pageWidth, pageHeight),
                          _pressure(event),
                        );
                      }
                    : null,
                onPointerUp: widget.penModeEnabled
                    ? (event) {
                        if (event.pointer != _activeStylusPointer) return;
                        setState(() {
                          _activeStylusPointer = null;
                        });
                        widget.onStrokeEnd();
                      }
                    : null,
                onPointerCancel: widget.penModeEnabled
                    ? (event) {
                        if (event.pointer != _activeStylusPointer) return;
                        setState(() {
                          _activeStylusPointer = null;
                        });
                        widget.onStrokeEnd();
                      }
                    : null,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: widget.pinModeEnabled
                      ? (details) {
                          final Offset local = details.localPosition;

                          if (pendingPin != null) {
                            final Offset pinCenter = Offset(
                              pendingPin.xRatio * pageWidth,
                              pendingPin.yRatio * pageHeight,
                            );
                            widget.onDirectionChanged(
                              pendingPin,
                              _directionFromPoints(pinCenter, local),
                            );
                            return;
                          }

                          widget.onAddPin(
                            _normalize(local, pageWidth, pageHeight),
                          );
                        }
                      : null,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: Image.memory(
                          widget.imageBytes,
                          fit: BoxFit.fill,
                          gaplessPlayback: true,
                          filterQuality: FilterQuality.high,
                        ),
                      ),
                      Positioned.fill(
                        child: HandwritingLayer(strokes: widget.strokes),
                      ),
                      for (final PinData pin in widget.pins)
                        Positioned(
                          left: pin.xRatio * pageWidth -
                              PinMarker.markerWidth / 2,
                          top:
                              pin.yRatio * pageHeight - PinMarker.markerCenterY,
                          child: PinMarker(
                            key: ValueKey<String>(pin.id),
                            pin: pin,
                            selected: pin.id == widget.selectedPinId,
                            awaitingDirection:
                                pin.id == widget.pendingDirectionPinId,
                            onTap: () => widget.onPinTap(pin),
                            onDirectionChanged: (direction) {
                              widget.onDirectionChanged(pin, direction);
                            },
                            onMoveStart:
                                widget.pinModeEnabled && pendingPin == null
                                    ? (_) => _startMovingPin(pin)
                                    : null,
                            onMoveUpdate:
                                widget.pinModeEnabled && pendingPin == null
                                    ? (globalPosition) =>
                                        _updateMovingPin(pin, globalPosition)
                                    : null,
                            onMoveEnd:
                                widget.pinModeEnabled && pendingPin == null
                                    ? (globalPosition) =>
                                        _finishMovingPin(pin, globalPosition)
                                    : null,
                            onMoveCancel:
                                widget.pinModeEnabled && pendingPin == null
                                    ? () => _cancelMovingPin(pin)
                                    : null,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
