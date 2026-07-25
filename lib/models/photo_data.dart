import 'dart:typed_data';

class PhotoData {
  const PhotoData({
    required this.id,
    required this.fileName,
    required this.bytes,
    this.savedPath,
  });

  final String id;
  final String fileName;
  final Uint8List bytes;
  final String? savedPath;
}
