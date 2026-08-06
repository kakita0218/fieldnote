import 'package:fieldnote/models/drawing_stroke.dart';
import 'package:fieldnote/models/pin_data.dart';
import 'package:fieldnote/services/export_layout.dart';
import 'package:flutter_test/flutter_test.dart';

PinData _pin(String id, int number, int page) => PinData(
      id: id,
      number: number,
      pageNumber: page,
      xRatio: 0.5,
      yRatio: 0.5,
    );

void main() {
  test('書き出し時だけページ順と元番号順でピン番号を整理する', () {
    final List<PinData> pins = <PinData>[
      _pin('p1-1', 1, 1),
      _pin('p1-2', 2, 1),
      _pin('p1-5', 5, 1),
      _pin('p1-6', 6, 1),
      _pin('p2-4', 4, 2),
      _pin('p3-3', 3, 3),
    ];
    final Map<String, int> numbers = buildExportPinNumbers(pins);
    expect(numbers, <String, int>{
      'p1-1': 1,
      'p1-2': 2,
      'p1-5': 3,
      'p1-6': 4,
      'p2-4': 5,
      'p3-3': 6,
    });
    expect(pins.map((PinData pin) => pin.number), <int>[1, 2, 5, 6, 4, 3]);
  });

  test('ピン・図形・手書き・入力済み文字のページだけを抽出する', () {
    final Set<int> pages = buildAnnotatedPageNumbers(
      pins: <PinData>[_pin('pin', 1, 4)],
      strokesByPage: <int, List<DrawingStroke>>{
        2: const <DrawingStroke>[
          DrawingStroke(
            id: 'line',
            pageNumber: 2,
            kind: DrawingKind.line,
            points: <DrawingPoint>[
              DrawingPoint(position: Offset(0.1, 0.1)),
              DrawingPoint(position: Offset(0.2, 0.2)),
            ],
          ),
        ],
        3: const <DrawingStroke>[
          DrawingStroke(
            id: 'empty-text',
            pageNumber: 3,
            kind: DrawingKind.text,
            points: <DrawingPoint>[
              DrawingPoint(position: Offset(0.1, 0.1)),
            ],
          ),
        ],
      },
    );
    expect(pages, <int>{2, 4});
  });
}
