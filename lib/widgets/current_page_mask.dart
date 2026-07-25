import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';

/// PDF全体の座標や変形行列には手を加えず、現在ページの外側だけを覆う。
/// これにより、PDFとピンは同じ座標変換を使い続けるため位置がずれない。
class CurrentPageMask extends StatelessWidget {
  const CurrentPageMask({
    super.key,
    required this.controller,
    required this.currentPage,
    required this.maskColor,
  });

  final PdfControllerPinch controller;
  final int currentPage;
  final Color maskColor;

  Rect? _viewportPageRect() {
    try {
      final Rect? sceneRect = controller.getPageRect(currentPage);
      if (sceneRect == null) {
        return null;
      }
      final Offset topLeft =
          MatrixUtils.transformPoint(controller.value, sceneRect.topLeft);
      final Offset bottomRight =
          MatrixUtils.transformPoint(controller.value, sceneRect.bottomRight);
      return Rect.fromPoints(topLeft, bottomRight);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final Rect? pageRect = _viewportPageRect();
          if (pageRect == null) {
            return const SizedBox.expand();
          }

          return LayoutBuilder(
            builder: (context, constraints) {
              final double width = constraints.maxWidth;
              final double height = constraints.maxHeight;
              final Rect viewport = Rect.fromLTWH(0, 0, width, height);
              final Rect visible = pageRect.intersect(viewport);

              if (visible.isEmpty) {
                return ColoredBox(color: maskColor);
              }

              return Stack(
                children: [
                  Positioned(
                    left: 0,
                    top: 0,
                    right: 0,
                    height: visible.top.clamp(0.0, height),
                    child: ColoredBox(color: maskColor),
                  ),
                  Positioned(
                    left: 0,
                    top: visible.bottom.clamp(0.0, height),
                    right: 0,
                    bottom: 0,
                    child: ColoredBox(color: maskColor),
                  ),
                  Positioned(
                    left: 0,
                    top: visible.top.clamp(0.0, height),
                    width: visible.left.clamp(0.0, width),
                    height: visible.height.clamp(0.0, height),
                    child: ColoredBox(color: maskColor),
                  ),
                  Positioned(
                    left: visible.right.clamp(0.0, width),
                    top: visible.top.clamp(0.0, height),
                    right: 0,
                    height: visible.height.clamp(0.0, height),
                    child: ColoredBox(color: maskColor),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
