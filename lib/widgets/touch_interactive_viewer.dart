import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

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
  });

  final TransformationController transformationController;
  final Widget child;
  final bool interactionEnabled;
  final double minScale;
  final double maxScale;

  @override
  State<TouchInteractiveViewer> createState() => _TouchInteractiveViewerState();
}

class _TouchInteractiveViewerState extends State<TouchInteractiveViewer> {
  Matrix4 _startMatrix = Matrix4.identity();
  Offset _startFocalPoint = Offset.zero;
  double _startScale = 1;

  double _matrixScale(Matrix4 matrix) => matrix.getMaxScaleOnAxis();

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

    widget.transformationController.value = next;
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: widget.interactionEnabled
            ? <Type, GestureRecognizerFactory>{
                ScaleGestureRecognizer: GestureRecognizerFactoryWithHandlers<
                    ScaleGestureRecognizer>(
                  () => ScaleGestureRecognizer(
                    supportedDevices: const <PointerDeviceKind>{
                      PointerDeviceKind.touch,
                    },
                  ),
                  (ScaleGestureRecognizer instance) {
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
    );
  }
}
