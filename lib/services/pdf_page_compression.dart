import 'dart:typed_data';

import 'package:image/image.dart' as image_codec;

/// Encodes a rendered PDF page for embedding in a fallback PDF export.
///
/// Line drawings often compress better as PNG, while scanned or photographic
/// pages are usually much smaller as JPEG. Keep whichever representation is
/// smaller so compression can never inflate the embedded page image.
Uint8List encodePdfPageForEmbedding(Uint8List sourceBytes) {
  final image_codec.Image? decoded = image_codec.decodeImage(sourceBytes);
  if (decoded == null) {
    throw StateError('PDFページ画像を圧縮できませんでした。');
  }
  final Uint8List jpeg = image_codec.encodeJpg(decoded, quality: 88);
  return jpeg.length < sourceBytes.length ? jpeg : sourceBytes;
}
