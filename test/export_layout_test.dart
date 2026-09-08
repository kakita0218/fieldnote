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
  test('ピン番号はPDFごとの既存最大番号から続け、欠番は詰めない', () {
    final List<PinData> pins = <PinData>[
      _pin('a-1', 1, 1).copyWith(documentId: 'pdf-a'),
      _pin('a-2', 2, 1).copyWith(documentId: 'pdf-a'),
      _pin('a-3', 3, 1).copyWith(documentId: 'pdf-a'),
      _pin('b-1', 1, 1).copyWith(documentId: 'pdf-b'),
    ];

    expect(nextPinNumberForDocument(pins, 'pdf-a'), 4);
    expect(
      nextPinNumberForDocument(
        pins.where((PinData pin) => pin.id != 'a-1'),
        'pdf-a',
      ),
      4,
    );
    expect(
      nextPinNumberForDocument(
        pins.where((PinData pin) => pin.id != 'a-3'),
        'pdf-a',
      ),
      3,
    );
    expect(nextPinNumberForDocument(pins, 'pdf-b'), 2);
  });

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

  test('書き出し番号もPDFごとに1から振り直す', () {
    final List<PinData> pins = <PinData>[
      _pin('a-page-2', 5, 2).copyWith(documentId: 'pdf-a'),
      _pin('a-page-1', 8, 1).copyWith(documentId: 'pdf-a'),
      _pin('b-page-3', 4, 3).copyWith(documentId: 'pdf-b'),
    ];

    expect(
      buildExportPinNumbers(
        pins.where((PinData pin) => pin.documentId == 'pdf-a'),
      ),
      <String, int>{'a-page-1': 1, 'a-page-2': 2},
    );
    expect(
      buildExportPinNumbers(
        pins.where((PinData pin) => pin.documentId == 'pdf-b'),
      ),
      <String, int>{'b-page-3': 1},
    );
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
