import 'dart:convert';
import 'dart:typed_data';

import 'package:fieldnote/models/pin_data.dart';
import 'package:fieldnote/widgets/single_page_pdf_canvas.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('テキストモードでタップ・ダブルタップ・ドラッグを区別する', (WidgetTester tester) async {
    final TransformationController controller = TransformationController();
    int tapCount = 0;
    int doubleTapCount = 0;
    bool moveStarted = false;
    Offset? movedTo;
    Offset? moveEndedAt;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox.square(
              dimension: 400,
              child: SinglePagePdfCanvas(
                imageBytes: Uint8List.fromList(
                  base64Decode(
                    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
                    'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
                  ),
                ),
                pageAspectRatio: 1,
                transformationController: controller,
                pins: const <PinData>[],
                strokes: const [],
                pinModeEnabled: false,
                penModeEnabled: false,
                textModeEnabled: true,
                selectedPinId: null,
                pendingDirectionPinId: null,
                onAddPin: (_) {},
                onPinTap: (_) {},
                onDirectionChanged: (_, __) {},
                onPinMoveStart: (_) {},
                onPinMoveUpdate: (_, __) {},
                onPinMoveEnd: (_, __) {},
                onPinMoveCancel: (_) {},
                onStrokeStart: (_, __) {},
                onStrokeUpdate: (_, __) {},
                onStrokeEnd: () {},
                onCanvasTap: (_) => tapCount++,
                onCanvasDoubleTap: (_) => doubleTapCount++,
                onAnnotationMoveStart: (_) {
                  moveStarted = true;
                  return true;
                },
                onAnnotationMoveUpdate: (Offset position) => movedTo = position,
                onAnnotationMoveEnd: (Offset position) =>
                    moveEndedAt = position,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Offset center = tester.getCenter(find.byType(SinglePagePdfCanvas));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 350));
    expect(tapCount, 1);
    expect(doubleTapCount, 0);

    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 350));
    expect(doubleTapCount, 1);

    final TestGesture gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(30, 20));
    await tester.pump();
    await gesture.moveBy(const Offset(50, 40));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(moveStarted, isTrue);
    expect(movedTo, isNotNull);
    expect(moveEndedAt, isNotNull);
    expect(moveEndedAt!.dx, greaterThan(0.5));
    expect(moveEndedAt!.dy, greaterThan(0.5));
    controller.dispose();
  });
}
