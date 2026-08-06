import 'package:fieldnote/widgets/touch_interactive_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pin panel resize keeps the previously visible PDF range', () {
    const Size beforeSize = Size(1000, 600);
    const Size afterSize = Size(680, 600);
    final Rect beforeContent = fittedPdfContentRect(
      viewportSize: beforeSize,
      pageAspectRatio: 1.5,
    );
    final Matrix4 zoomed = Matrix4.identity()
      ..setEntry(0, 0, 2)
      ..setEntry(1, 1, 2)
      ..setTranslationRaw(-450, -300, 0);
    final PdfVisibleRange before = capturePdfVisibleRange(
      matrix: zoomed,
      viewportSize: beforeSize,
      contentRect: beforeContent,
    )!;

    final Rect afterContent = fittedPdfContentRect(
      viewportSize: afterSize,
      pageAspectRatio: 1.5,
    );
    final Matrix4 restored = restorePdfVisibleRange(
      visibleRange: before,
      viewportSize: afterSize,
      contentRect: afterContent,
    );
    final Rect after = capturePdfVisibleRange(
      matrix: restored,
      viewportSize: afterSize,
      contentRect: afterContent,
    )!
        .normalizedRect;

    expect(after.left, lessThanOrEqualTo(before.normalizedRect.left + 0.0001));
    expect(after.top, lessThanOrEqualTo(before.normalizedRect.top + 0.0001));
    expect(
      after.right,
      greaterThanOrEqualTo(before.normalizedRect.right - 0.0001),
    );
    expect(
      after.bottom,
      greaterThanOrEqualTo(before.normalizedRect.bottom - 0.0001),
    );
  });

  test('pin panel resize keeps a fully visible PDF fully visible', () {
    const Size beforeSize = Size(1000, 600);
    const Size afterSize = Size(680, 600);
    final PdfVisibleRange before = capturePdfVisibleRange(
      matrix: Matrix4.identity(),
      viewportSize: beforeSize,
      contentRect: fittedPdfContentRect(
        viewportSize: beforeSize,
        pageAspectRatio: 1.5,
      ),
    )!;
    final Rect afterContent = fittedPdfContentRect(
      viewportSize: afterSize,
      pageAspectRatio: 1.5,
    );
    final PdfVisibleRange after = capturePdfVisibleRange(
      matrix: restorePdfVisibleRange(
        visibleRange: before,
        viewportSize: afterSize,
        contentRect: afterContent,
      ),
      viewportSize: afterSize,
      contentRect: afterContent,
    )!;

    expect(after.normalizedRect.left, closeTo(0, 0.0001));
    expect(after.normalizedRect.top, closeTo(0, 0.0001));
    expect(after.normalizedRect.right, closeTo(1, 0.0001));
    expect(after.normalizedRect.bottom, closeTo(1, 0.0001));
  });

  test('縮小状態ではPDFを画面中央へ戻す', () {
    final Matrix4 input = Matrix4.identity()..setTranslationRaw(900, -700, 0);
    final Matrix4 constrained = constrainPdfTransformation(
      matrix: input,
      viewportSize: const Size(400, 400),
      contentRect: const Rect.fromLTWH(100, 50, 200, 300),
    );

    expect(constrained.storage[12], 0);
    expect(constrained.storage[13], 0);
  });

  test('拡大状態でもPDFの端が表示領域から離れない', () {
    final Matrix4 input = Matrix4.diagonal3Values(2, 2, 1)
      ..setTranslationRaw(900, -2000, 0);
    const Rect content = Rect.fromLTWH(100, 50, 200, 300);
    final Matrix4 constrained = constrainPdfTransformation(
      matrix: input,
      viewportSize: const Size(400, 400),
      contentRect: content,
    );
    final double scale = constrained.getMaxScaleOnAxis();
    final double left = content.left * scale + constrained.storage[12];
    final double right = content.right * scale + constrained.storage[12];
    final double top = content.top * scale + constrained.storage[13];
    final double bottom = content.bottom * scale + constrained.storage[13];

    expect(left, 0);
    expect(right, 400);
    expect(top, lessThanOrEqualTo(0));
    expect(bottom, greaterThanOrEqualTo(400));
  });

  testWidgets('2本指専用モードでは1本指を無視してピンチは受け付ける', (WidgetTester tester) async {
    final TransformationController controller = TransformationController();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox.square(
            dimension: 400,
            child: TouchInteractiveViewer(
              transformationController: controller,
              minimumPointerCount: 2,
              contentRect: const Rect.fromLTWH(0, 0, 400, 400),
              child: const ColoredBox(color: Colors.white),
            ),
          ),
        ),
      ),
    );

    await tester.drag(
      find.byType(TouchInteractiveViewer),
      const Offset(80, 0),
    );
    await tester.pump();
    expect(controller.value.getMaxScaleOnAxis(), 1);
    expect(controller.value.storage[12], 0);

    final Rect viewer = tester.getRect(find.byType(TouchInteractiveViewer));
    final TestGesture first = await tester.startGesture(
      viewer.centerLeft + const Offset(120, 0),
      pointer: 1,
    );
    final TestGesture second = await tester.startGesture(
      viewer.centerRight - const Offset(120, 0),
      pointer: 2,
    );
    await tester.pump();
    await first.moveBy(const Offset(-60, 0));
    await second.moveBy(const Offset(60, 0));
    await tester.pump();

    expect(controller.value.getMaxScaleOnAxis(), greaterThan(1));
    await first.up();
    await second.up();
    controller.dispose();
  });
}
