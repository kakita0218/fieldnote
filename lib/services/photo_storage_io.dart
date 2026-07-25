import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

Future<String?> savePinPhoto({
  required int pinNumber,
  required int photoNumber,
  required Uint8List bytes,
}) async {
  final Directory documents = await getApplicationDocumentsDirectory();
  final Directory photoDirectory = Directory(
    '${documents.path}${Platform.pathSeparator}FieldNote'
    '${Platform.pathSeparator}写真'
    '${Platform.pathSeparator}${pinNumber.toString().padLeft(3, '0')}',
  );

  if (!await photoDirectory.exists()) {
    await photoDirectory.create(recursive: true);
  }

  final String fileName = '${photoNumber.toString().padLeft(3, '0')}.jpg';
  final File file = File(
    '${photoDirectory.path}${Platform.pathSeparator}$fileName',
  );
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}
