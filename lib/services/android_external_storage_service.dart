import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AndroidExternalStorageService {
  static const MethodChannel _channel =
      MethodChannel('jp.fieldnote/android_storage');

  static bool get isAvailable =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<bool> hasAccess() async {
    if (!isAvailable) return true;
    try {
      return await _channel.invokeMethod<bool>('hasStorageAccess') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<bool> selectDirectory() async {
    if (!isAvailable) return true;
    try {
      return await _channel.invokeMethod<bool>('selectStorageDirectory') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  static Future<String?> selectedDirectoryName() async {
    if (!isAvailable) return null;
    try {
      return await _channel.invokeMethod<String>('storageDirectoryName');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<void> syncProject({
    required String projectId,
    required String localPath,
  }) async {
    if (!isAvailable) return;
    if (!await hasAccess()) {
      throw StateError('保存先フォルダを再選択してください。');
    }
    await _channel.invokeMethod<void>('syncProjectDirectory', <String, Object>{
      'projectId': projectId,
      'localPath': localPath,
    });
  }

  static Future<void> deleteProject(String projectId) async {
    if (!isAvailable) return;
    if (!await hasAccess()) {
      throw StateError('保存先フォルダを再選択してください。');
    }
    await _channel.invokeMethod<void>(
      'deleteProjectDirectory',
      <String, Object>{'projectId': projectId},
    );
  }
}
