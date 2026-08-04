import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:fieldnote/models/drawing_stroke.dart';
import 'package:fieldnote/widgets/handwriting_layer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const DrawingStroke stroke = DrawingStroke(
    id: 'stroke-1',
    pageNumber: 1,
    width: 4,
    points: <DrawingPoint>[
      DrawingPoint(position: Offset(0.5, 0.5), pressure: 0.5),
    ],
  );

  test('筆圧は0〜1に制限し、強い筆圧ほど太くする', () {
    expect(
      drawingStrokeWidth(stroke, -10),
      drawingStrokeWidth(stroke, 0),
    );
    expect(
      drawingStrokeWidth(stroke, 10),
      drawingStrokeWidth(stroke, 1),
    );
    expect(
      drawingStrokeWidth(stroke, 1),
      greaterThan(drawingStrokeWidth(stroke, 0)),
    );
  });

  test('1点だけのストロークも書き出し共通描画で点になる', () async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 100, 100),
      Paint()..color = Colors.white,
    );
    paintDrawingStrokes(
      canvas,
      const Size(100, 100),
      const <DrawingStroke>[stroke],
    );

    final ui.Image image = await recorder.endRecording().toImage(100, 100);
    final ByteData data =
        (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    image.dispose();
    final int centerPixel = (50 * 100 + 50) * 4;

    expect(data.getUint8(centerPixel), greaterThan(200));
    expect(data.getUint8(centerPixel + 1), lessThan(100));
    expect(data.getUint8(centerPixel + 2), lessThan(100));
    expect(data.getUint8(centerPixel + 3), 255);
  });

  test('矩形は対角線を描かず外枠だけを描画する', () async {
    const DrawingStroke rectangle = DrawingStroke(
      id: 'rectangle-1',
      pageNumber: 1,
      width: 4,
      color: Colors.red,
      kind: DrawingKind.rectangle,
      points: <DrawingPoint>[
        DrawingPoint(position: Offset(0.2, 0.2)),
        DrawingPoint(position: Offset(0.8, 0.8)),
      ],
    );
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 100, 100),
      Paint()..color = Colors.white,
    );
    paintDrawingStrokes(
      canvas,
      const Size(100, 100),
      const <DrawingStroke>[rectangle],
    );

    final ui.Image image = await recorder.endRecording().toImage(100, 100);
    final ByteData data =
        (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    image.dispose();
    final int centerPixel = (50 * 100 + 50) * 4;
    final int borderPixel = (20 * 100 + 50) * 4;

    expect(data.getUint8(centerPixel), 255);
    expect(data.getUint8(centerPixel + 1), 255);
    expect(data.getUint8(centerPixel + 2), 255);
    expect(data.getUint8(borderPixel), greaterThan(200));
    expect(data.getUint8(borderPixel + 1), lessThan(100));
  });
}
