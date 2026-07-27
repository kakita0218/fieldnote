import 'package:fieldnote/models/photo_board.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('各電子看板テンプレートは指定された6工程を保持する', () {
    expect(
      PhotoBoardTemplate.core.steps,
      <String>[
        '施工前',
        '鉄筋探査状況',
        'コア採取状況',
        'コア採取',
        '無収縮モルタル充填完了',
        '復旧完了',
      ],
    );
    expect(
      PhotoBoardTemplate.chipping.steps,
      <String>[
        '施工前',
        '鉄筋探査状況',
        '斫り状況',
        '斫り完了',
        '無収縮モルタル充填完了',
        '復旧完了',
      ],
    );
    expect(
      PhotoBoardTemplate.asbestos.steps,
      <String>[
        '採取前',
        '寸法確認(1)',
        '寸法確認(2)',
        '湿潤状況',
        '採取状況',
        '塗装完了',
      ],
    );
  });

  test('工程位置はテンプレートごとに独立して保持する', () {
    const PhotoBoardConfig initial = PhotoBoardConfig(
      enabled: true,
      businessName: '業務',
      facilityName: '施設',
      shootingLocation: 'No.1',
      template: PhotoBoardTemplate.core,
      templateSteps: <PhotoBoardTemplate, int>{
        PhotoBoardTemplate.core: 2,
        PhotoBoardTemplate.chipping: 4,
        PhotoBoardTemplate.asbestos: 1,
      },
      position: PhotoBoardPosition.bottomLeft,
    );

    expect(initial.stepLabel, 'コア採取状況');
    final PhotoBoardConfig chipping =
        initial.copyWith(template: PhotoBoardTemplate.chipping);
    expect(chipping.stepLabel, '無収縮モルタル充填完了');
    expect(
      chipping.withSelectedStep(5).templateSteps[PhotoBoardTemplate.core],
      2,
    );
    expect(
      chipping.copyWith(position: PhotoBoardPosition.topRight).position,
      PhotoBoardPosition.topRight,
    );
  });
}
