import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

Matrix4 constrainPdfTransformation({
  required Matrix4 matrix,
  required Size viewportSize,
  required Rect contentRect,
}) {
  if (viewportSize.isEmpty) return matrix;
  final double scale = matrix.getMaxScaleOnAxis();
  double translationX = matrix.storage[12];
  double translationY = matrix.storage[13];
  final double scaledWidth = contentRect.width * scale;
  final double scaledHeight = contentRect.height * scale;

  if (scaledWidth <= viewportSize.width) {
    translationX =
        (viewportSize.width - scaledWidth) / 2 - contentRect.left * scale;
  } else {
    translationX = translationX
        .clamp(
          viewportSize.width - contentRect.right * scale,
          -contentRect.left * scale,
        )
        .toDouble();
  }
  if (scaledHeight <= viewportSize.height) {
    translationY =
        (viewportSize.height - scaledHeight) / 2 - contentRect.top * scale;
  } else {
    translationY = translationY
        .clamp(
          viewportSize.height - contentRect.bottom * scale,
          -contentRect.top * scale,
        )
        .toDouble();
  }

  return matrix.clone()..setTranslationRaw(translationX, translationY, 0);
}

class _MinimumPointerScaleGestureRecognizer extends ScaleGestureRecognizer {
  _MinimumPointerScaleGestureRecognizer({
    required this.minimumPointerCount,
    super.supportedDevices,
  });

  int minimumPointerCount;
  final Set<int> _trackedPointers = <int>{};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _trackedPointers.add(event.pointer);
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    final bool isEnd = event is PointerUpEvent || event is PointerCancelEvent;
    if (event is PointerMoveEvent &&
        _trackedPointers.length < minimumPointerCount) {
      return;
    }
    super.handleEvent(event);
    if (isEnd) {
      _trackedPointers.remove(event.pointer);
    }
  }

  @override
  void rejectGesture(int pointer) {
    _trackedPointers.remove(pointer);
    super.rejectGesture(pointer);
  }

  @override
  void dispose() {
    _trackedPointers.clear();
    super.dispose();
  }
}

/// 指（touch）だけでパン・ピンチズームを行うビューア。
/// Apple Pencil のイベントはジェスチャー競合に参加しないため、
/// ペン描画中にPDFが動かない。
class TouchInteractiveViewer extends StatefulWidget {
  const TouchInteractiveViewer({
    super.key,
    required this.transformationController,
    required this.child,
    this.interactionEnabled = true,
    this.minScale = 1,
    this.maxScale = 10,
    this.contentRect,
    this.minimumPointerCount = 1,
  }) : assert(minimumPointerCount > 0);

  final TransformationController transformationController;
  final Widget child;
  final bool interactionEnabled;
  final double minScale;
  final double maxScale;
  final Rect? contentRect;
  final int minimumPointerCount;

  @override
  State<TouchInteractiveViewer> createState() => _TouchInteractiveViewerState();
}

class _TouchInteractiveViewerState extends State<TouchInteractiveViewer> {
  Matrix4 _startMatrix = Matrix4.identity();
  Offset _startFocalPoint = Offset.zero;
  double _startScale = 1;
  Size _viewportSize = Size.zero;

  double _matrixScale(Matrix4 matrix) => matrix.getMaxScaleOnAxis();

  Matrix4 _constrainToViewport(Matrix4 matrix) {
    if (_viewportSize.isEmpty) return matrix;
    return constrainPdfTransformation(
      matrix: matrix,
      viewportSize: _viewportSize,
      contentRect: widget.contentRect ?? (Offset.zero & _viewportSize),
    );
  }

  void _changeScale(double factor) {
    if (!widget.interactionEnabled || _viewportSize.isEmpty) return;
    final Matrix4 current = widget.transformationController.value;
    final double currentScale = _matrixScale(current);
    final double requestedScale = (currentScale * factor)
        .clamp(widget.minScale, widget.maxScale)
        .toDouble();
    if (requestedScale == currentScale) return;
    final double relativeScale = requestedScale / currentScale;
    final Offset center = _viewportSize.center(Offset.zero);
    final Matrix4 next = Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(relativeScale, relativeScale, relativeScale, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1)
      ..multiply(current);
    widget.transformationController.value = _constrainToViewport(next);
  }

  void _onScaleStart(ScaleStartDetails details) {
    _startMatrix = widget.transformationController.value.clone();
    _startFocalPoint = details.localFocalPoint;
    _startScale = _matrixScale(_startMatrix);
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final requestedScale = (_startScale * details.scale)
        .clamp(widget.minScale, widget.maxScale)
        .toDouble();
    final relativeScale = requestedScale / _startScale;
    final currentFocalPoint = details.localFocalPoint;

    final Matrix4 next = Matrix4.identity()
      ..translateByDouble(
        currentFocalPoint.dx,
        currentFocalPoint.dy,
        0.0,
        1.0,
      )
      ..scaleByDouble(
        relativeScale,
        relativeScale,
        relativeScale,
        1.0,
      )
      ..translateByDouble(
        -_startFocalPoint.dx,
        -_startFocalPoint.dy,
        0.0,
        1.0,
      )
      ..multiply(_startMatrix);

    widget.transformationController.value = _constrainToViewport(next);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _viewportSize = constraints.biggest;
        return Semantics(
          container: true,
          explicitChildNodes: true,
          label: 'PDF表示',
          hint: widget.minimumPointerCount > 1
              ? '2本指で拡大縮小・移動'
              : '2本指で拡大縮小、1本指で移動',
          onIncrease:
              widget.interactionEnabled ? () => _changeScale(1.25) : null,
          onDecrease:
              widget.interactionEnabled ? () => _changeScale(0.8) : null,
          child: ClipRect(
            child: RawGestureDetector(
              behavior: HitTestBehavior.opaque,
              gestures: widget.interactionEnabled
                  ? <Type, GestureRecognizerFactory>{
                      _MinimumPointerScaleGestureRecognizer:
                          GestureRecognizerFactoryWithHandlers<
                              _MinimumPointerScaleGestureRecognizer>(
                        () => _MinimumPointerScaleGestureRecognizer(
                          minimumPointerCount: widget.minimumPointerCount,
                          supportedDevices: const <PointerDeviceKind>{
                            PointerDeviceKind.touch,
                          },
                        ),
                        (_MinimumPointerScaleGestureRecognizer instance) {
                          instance.minimumPointerCount =
                              widget.minimumPointerCount;
                          instance
                            ..onStart = _onScaleStart
                            ..onUpdate = _onScaleUpdate;
                        },
                      ),
                    }
                  : const <Type, GestureRecognizerFactory>{},
              child: AnimatedBuilder(
                animation: widget.transformationController,
                builder: (context, child) => Transform(
                  transform: widget.transformationController.value,
                  alignment: Alignment.topLeft,
                  child: child,
                ),
                child: widget.child,
              ),
            ),
          ),
        );
      },
    );
  }
}
