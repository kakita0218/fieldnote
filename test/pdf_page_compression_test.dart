import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image_codec;
import 'package:fieldnote/services/pdf_page_compression.dart';

void main() {
  test('線画は元のPNGより大きくしない', () {
    final image_codec.Image source = image_codec.Image(
      width: 1200,
      height: 1600,
    );
    image_codec.fill(source, color: image_codec.ColorRgb8(250, 250, 250));
    for (int y = 80; y < 1520; y += 80) {
      image_codec.drawLine(
        source,
        x1: 60,
        y1: y,
        x2: 1140,
        y2: y,
        color: image_codec.ColorRgb8(25, 25, 25),
        thickness: 2,
      );
    }
    final Uint8List png = image_codec.encodePng(source);

    final Uint8List compressed = encodePdfPageForEmbedding(png);
    final image_codec.Image? decoded = image_codec.decodeImage(compressed);

    expect(decoded, isNotNull);
    expect(decoded!.width, source.width);
    expect(decoded.height, source.height);
    expect(compressed.length, lessThanOrEqualTo(png.length));
  });

  test('写真調のページは高品質JPEGを採用する', () {
    final image_codec.Image source = image_codec.Image(
      width: 800,
      height: 1000,
    );
    final math.Random random = math.Random(42);
    for (int y = 0; y < source.height; y++) {
      for (int x = 0; x < source.width; x++) {
        source.setPixelRgb(
          x,
          y,
          random.nextInt(256),
          random.nextInt(256),
          random.nextInt(256),
        );
      }
    }
    final Uint8List png = image_codec.encodePng(source);

    final Uint8List compressed = encodePdfPageForEmbedding(png);

    expect(compressed.length, lessThan(png.length));
    expect(compressed[0], 0xFF);
    expect(compressed[1], 0xD8);
  });
}
