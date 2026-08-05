import 'package:fieldnote/models/drawing_stroke.dart';
import 'package:fieldnote/services/drawing_serialization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('図形・文字・ペン種別・透過率を保存して復元できる', () {
    const DrawingStroke original = DrawingStroke(
      id: 'text-1',
      pageNumber: 3,
      points: <DrawingPoint>[
        DrawingPoint(position: Offset(0.25, 0.4), pressure: 0.8),
      ],
      width: 7,
      color: Color(0xFF123456),
      opacity: 0.45,
      kind: DrawingKind.text,
      brush: DrawingBrush.highlighter,
      text: '点検済み',
      fontSize: 32,
      textBoxWidthRatio: 0.6,
    );

    final DrawingStroke restored =
        deserializeDrawingStroke(serializeDrawingStroke(original))!;

    expect(restored.id, original.id);
    expect(restored.pageNumber, original.pageNumber);
    expect(restored.kind, DrawingKind.text);
    expect(restored.brush, DrawingBrush.highlighter);
    expect(restored.opacity, 0.45);
    expect(restored.text, '点検済み');
    expect(restored.fontSize, 32);
    expect(restored.textBoxWidthRatio, 0.6);
    expect(restored.points.single.position, const Offset(0.25, 0.4));
    expect(restored.points.single.pressure, 0.8);
  });

  test('旧形式の手書きデータも従来のペンとして復元できる', () {
    final DrawingStroke restored = deserializeDrawingStroke(
      <String, dynamic>{
        'id': 'legacy',
        'pageNumber': 1,
        'points': <Map<String, double>>[
          <String, double>{'x': 0.1, 'y': 0.2},
        ],
      },
    )!;

    expect(restored.kind, DrawingKind.freehand);
    expect(restored.brush, DrawingBrush.fountain);
    expect(restored.opacity, 1);
    expect(restored.textBoxWidthRatio, 0.45);
  });
}
