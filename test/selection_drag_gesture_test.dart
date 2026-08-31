import 'dart:convert';
import 'dart:typed_data';

import 'package:fieldnote/models/pin_data.dart';
import 'package:fieldnote/widgets/single_page_pdf_canvas.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('選択ツールのドラッグで範囲選択位置を通知する', (WidgetTester tester) async {
    final TransformationController controller = TransformationController();
    Offset? startedAt;
    Offset? updatedAt;
    Offset? endedAt;

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
                selectionModeEnabled: true,
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
                onAnnotationTransformStart: (_) => false,
                onSelectionDragStart: (Offset value) => startedAt = value,
                onSelectionDragUpdate: (Offset value) => updatedAt = value,
                onSelectionDragEnd: (Offset value) => endedAt = value,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Rect canvas = tester.getRect(find.byType(SinglePagePdfCanvas));
    final TestGesture gesture =
        await tester.startGesture(canvas.topLeft + const Offset(80, 100));
    await gesture.moveBy(const Offset(40, 30));
    await tester.pump();
    await gesture.moveBy(const Offset(140, 110));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(startedAt, isNotNull);
    expect(updatedAt, isNotNull);
    expect(endedAt, isNotNull);
    expect(endedAt!.dx, greaterThan(startedAt!.dx));
    expect(endedAt!.dy, greaterThan(startedAt!.dy));
    controller.dispose();
  });
}
