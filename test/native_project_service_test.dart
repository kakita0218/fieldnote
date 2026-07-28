import 'package:fieldnote/services/native_project_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('jp.fieldnote/project');

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('案件フォルダをiOSの最近削除した項目へ移動する', () async {
    MethodCall? receivedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      receivedCall = call;
      return true;
    });

    await NativeProjectService.moveFileItemToTrash(
      '/documents/テスト案件',
    );

    expect(receivedCall?.method, 'moveFileItemToTrash');
    expect(
      receivedCall?.arguments,
      <String, dynamic>{'path': '/documents/テスト案件'},
    );
  });

  test('iOS側が移動を完了しなければ削除成功にしない', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async => false);

    await expectLater(
      NativeProjectService.moveFileItemToTrash('/documents/案件'),
      throwsStateError,
    );
  });
}
