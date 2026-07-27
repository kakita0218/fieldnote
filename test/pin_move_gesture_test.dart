import 'dart:convert';
import 'dart:typed_data';

import 'package:fieldnote/models/pin_data.dart';
import 'package:fieldnote/widgets/single_page_pdf_canvas.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ピンを長押ししてドラッグすると移動として通知する', (tester) async {
    final TransformationController controller = TransformationController();
    const PinData pin = PinData(
      id: 'pin-1',
      number: 1,
      pageNumber: 1,
      xRatio: 0.5,
      yRatio: 0.5,
    );
    bool started = false;
    Offset? movedTo;
    Offset? finishedAt;

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
                selectedPinId: null,
                pendingDirectionPinId: null,
                onAddPin: (_) {},
                onPinTap: (_) {},
                onDirectionChanged: (_, __) {},
                onPinMoveStart: (_) => started = true,
                onPinMoveUpdate: (_, position) => movedTo = position,
                onPinMoveEnd: (_, position) => finishedAt = position,
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

    final Finder marker = find.bySemanticsLabel('ピン 1');
    expect(marker, findsOneWidget);
    final Offset start = tester.getCenter(marker);
    final TestGesture gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 650));
    await gesture.moveTo(start + const Offset(70, 50));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(started, isTrue);
    expect(movedTo, isNotNull);
    expect(finishedAt, isNotNull);
    expect(finishedAt!.dx, greaterThan(0.5));
    expect(finishedAt!.dy, greaterThan(0.5));
    controller.dispose();
  });
}
