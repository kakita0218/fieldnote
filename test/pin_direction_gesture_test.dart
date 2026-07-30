import 'dart:convert';
import 'dart:typed_data';

import 'package:fieldnote/models/pin_data.dart';
import 'package:fieldnote/widgets/single_page_pdf_canvas.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('方向変更中は図面上のタップ位置から角度を通知する', (tester) async {
    final TransformationController controller = TransformationController();
    const PinData pin = PinData(
      id: 'pin-1',
      number: 1,
      pageNumber: 1,
      xRatio: 0.5,
      yRatio: 0.5,
    );
    double? selectedDirection;
    bool addedPin = false;

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
                pins: const <PinData>[pin],
                strokes: const [],
                pinModeEnabled: true,
                penModeEnabled: false,
                selectedPinId: pin.id,
                pendingDirectionPinId: pin.id,
                onAddPin: (_) => addedPin = true,
                onPinTap: (_) {},
                onDirectionChanged: (_, direction) {
                  selectedDirection = direction;
                },
                onPinMoveStart: (_) {},
                onPinMoveUpdate: (_, __) {},
                onPinMoveEnd: (_, __) {},
                onPinMoveCancel: (_) {},
                onStrokeStart: (_, __) {},
                onStrokeUpdate: (_, __) {},
                onStrokeEnd: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Rect canvas = tester.getRect(find.byType(SinglePagePdfCanvas));
    await tester.tapAt(
      Offset(canvas.left + canvas.width * 0.8, canvas.center.dy),
    );
    await tester.pump();

    expect(addedPin, isFalse);
    expect(selectedDirection, isNotNull);
    expect(selectedDirection!, closeTo(90, 0.1));
    controller.dispose();
  });

  testWidgets('ペンモード中はピン上のドラッグで方向を変更しない', (tester) async {
    final TransformationController controller = TransformationController();
    const PinData pin = PinData(
      id: 'pin-1',
      number: 1,
      pageNumber: 1,
      xRatio: 0.5,
      yRatio: 0.5,
    );
    int directionChanges = 0;
    int directionStarts = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox.square(
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
              pins: const <PinData>[pin],
              strokes: const [],
              pinModeEnabled: false,
              penModeEnabled: true,
              selectedPinId: pin.id,
              pendingDirectionPinId: null,
              onAddPin: (_) {},
              onPinTap: (_) {},
              onDirectionChanged: (_, __) => directionChanges++,
              onDirectionChangeStart: (_) => directionStarts++,
              onPinMoveStart: (_) {},
              onPinMoveUpdate: (_, __) {},
              onPinMoveEnd: (_, __) {},
              onPinMoveCancel: (_) {},
              onStrokeStart: (_, __) {},
              onStrokeUpdate: (_, __) {},
              onStrokeEnd: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Offset marker = tester.getCenter(find.bySemanticsLabel('ピン 1'));
    final TestGesture gesture = await tester.startGesture(marker);
    await gesture.moveBy(const Offset(35, 5));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(directionChanges, 0);
    expect(directionStarts, 0);
    controller.dispose();
  });

  testWidgets('ピンモード中の方向ドラッグは開始・変更・終了を通知する', (tester) async {
    final TransformationController controller = TransformationController();
    const PinData pin = PinData(
      id: 'pin-1',
      number: 1,
      pageNumber: 1,
      xRatio: 0.5,
      yRatio: 0.5,
    );
    int starts = 0;
    int changes = 0;
    int ends = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox.square(
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
              pins: const <PinData>[pin],
              strokes: const [],
              pinModeEnabled: true,
              penModeEnabled: false,
              selectedPinId: pin.id,
              pendingDirectionPinId: null,
              onAddPin: (_) {},
              onPinTap: (_) {},
              onDirectionChanged: (_, __) => changes++,
              onDirectionChangeStart: (_) => starts++,
              onDirectionChangeEnd: (_) => ends++,
              onPinMoveStart: (_) {},
              onPinMoveUpdate: (_, __) {},
              onPinMoveEnd: (_, __) {},
              onPinMoveCancel: (_) {},
              onStrokeStart: (_, __) {},
              onStrokeUpdate: (_, __) {},
              onStrokeEnd: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Offset marker = tester.getCenter(find.bySemanticsLabel('ピン 1'));
    final TestGesture gesture = await tester.startGesture(marker);
    await tester.pump();
    await gesture.moveBy(const Offset(60, 10));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(starts, 1);
    expect(changes, greaterThanOrEqualTo(1));
    expect(ends, 1);
    controller.dispose();
  });
}
