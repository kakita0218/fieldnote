import 'dart:ui';

import 'photo_board.dart';

/// Defines the electronic board geometry shared by the live preview and the
/// JPEG compositor.
abstract final class PhotoBoardLayout {
  static const double landscapeWidthRatio = 0.39;
  static const double portraitWidthRatio = 0.82;
  static const double heightToWidthRatio = 0.64;
  static const double marginToShortSideRatio = 0.035;

  static Rect rectFor(Size canvasSize, PhotoBoardPosition position) {
    assert(canvasSize.width > 0 && canvasSize.height > 0);

    final bool landscape = canvasSize.width >= canvasSize.height;
    final double boardWidth = canvasSize.width *
        (landscape ? landscapeWidthRatio : portraitWidthRatio);
    final double boardHeight = boardWidth * heightToWidthRatio;
    final double margin = canvasSize.shortestSide * marginToShortSideRatio;
    final double left =
        position.isLeft ? margin : canvasSize.width - boardWidth - margin;
    final double top =
        position.isTop ? margin : canvasSize.height - boardHeight - margin;

    return Rect.fromLTWH(left, top, boardWidth, boardHeight);
  }

  static Rect normalizedRectFor(
    Size canvasSize,
    PhotoBoardPosition position,
  ) {
    final Rect rect = rectFor(canvasSize, position);
    return Rect.fromLTWH(
      rect.left / canvasSize.width,
      rect.top / canvasSize.height,
      rect.width / canvasSize.width,
      rect.height / canvasSize.height,
    );
  }

  static Rect normalizedRectForAspectRatio(
    double aspectRatio,
    PhotoBoardPosition position,
  ) {
    assert(aspectRatio > 0);
    return normalizedRectFor(Size(aspectRatio, 1), position);
  }

  static PhotoBoardPosition positionNearestTo(
    Size canvasSize,
    Offset point,
  ) {
    final bool left = point.dx < canvasSize.width / 2;
    final bool top = point.dy < canvasSize.height / 2;
    if (top) {
      return left ? PhotoBoardPosition.topLeft : PhotoBoardPosition.topRight;
    }
    return left
        ? PhotoBoardPosition.bottomLeft
        : PhotoBoardPosition.bottomRight;
  }
}
