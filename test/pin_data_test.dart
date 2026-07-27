import 'package:fieldnote/models/pin_data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ピンを移動しても写真・看板設定を保持する', () {
    const PinData original = PinData(
      id: 'pin-1',
      number: 1,
      pageNumber: 2,
      xRatio: 0.2,
      yRatio: 0.3,
      photoCount: 4,
      boardEnabled: true,
      boardTemplateId: 'chipping',
      boardShootingLocation: 'J2F-2',
      boardChippingStep: 4,
      boardPositionId: 'topRight',
    );

    final PinData moved = original.copyWith(xRatio: 0.75, yRatio: 0.8);

    expect(moved.xRatio, 0.75);
    expect(moved.yRatio, 0.8);
    expect(moved.photoCount, 4);
    expect(moved.boardTemplateId, 'chipping');
    expect(moved.boardChippingStep, 4);
    expect(moved.boardPositionId, 'topRight');
  });
}
