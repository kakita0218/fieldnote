import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NativeProjectService {
  static const MethodChannel _channel = MethodChannel('jp.fieldnote/project');

  static bool get isAvailable =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static Future<int?> beginBackgroundSave(String reason) async {
    if (!isAvailable) return null;
    try {
      return await _channel.invokeMethod<int>(
        'beginBackgroundSave',
        <String, dynamic>{'reason': reason},
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<void> endBackgroundSave(int? identifier) async {
    if (!isAvailable || identifier == null) return;
    try {
      await _channel.invokeMethod<void>(
        'endBackgroundSave',
        <String, dynamic>{'identifier': identifier},
      );
    } on PlatformException {
      // Saving is already finished; background-task cleanup is best effort.
    } on MissingPluginException {
      // Older builds do not have the native background-task bridge.
    }
  }

  static Future<void> writeAnnotatedPdf({
    required String sourcePath,
    required String outputPath,
    required List<Map<String, dynamic>> pins,
    required List<Map<String, dynamic>> strokes,
  }) async {
    if (!isAvailable) return;
    await _channel.invokeMethod<void>(
      'writeAnnotatedPdf',
      <String, dynamic>{
        'sourcePath': sourcePath,
        'outputPath': outputPath,
        'pins': pins,
        'strokes': strokes,
      },
    );
  }

  static Future<void> synchronizePencilDrawings(String sourcePath) async {
    if (!isAvailable) return;
    await _channel.invokeMethod<void>(
      'synchronizePencilDrawings',
      <String, dynamic>{'sourcePath': sourcePath},
    );
  }

  static Future<bool> openPencilEditor({
    required String sourcePath,
    required String title,
  }) async {
    if (!isAvailable) return false;
    return await _channel.invokeMethod<bool>(
          'openPencilEditor',
          <String, dynamic>{
            'sourcePath': sourcePath,
            'title': title,
          },
        ) ??
        false;
  }

  static Future<Uint8List> composePhotoBoard({
    required Uint8List jpegBytes,
    required String businessName,
    required String facilityName,
    required String shootingDate,
    required String shootingLocation,
    required String workStatus,
  }) async {
    if (!isAvailable) return jpegBytes;
    final Uint8List? result = await _channel.invokeMethod<Uint8List>(
      'composePhotoBoard',
      <String, dynamic>{
        'jpegBytes': jpegBytes,
        'businessName': businessName,
        'facilityName': facilityName,
        'shootingDate': shootingDate,
        'shootingLocation': shootingLocation,
        'workStatus': workStatus,
      },
    );
    if (result == null || result.isEmpty) {
      throw StateError('電子看板を写真へ合成できませんでした。');
    }
    return result;
  }
}
