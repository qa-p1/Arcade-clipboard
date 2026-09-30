import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

class InviteQrDecoder {
  static const int maxFileBytes = 5 * 1024 * 1024;
  static const int maxDimension = 4096;
  static const int maxPixels = 12 * 1024 * 1024;

  String decode(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxFileBytes) {
      throw const FormatException('Choose an image under 5 MB.');
    }
    final dimensions = _dimensions(bytes);
    if (dimensions == null) {
      throw const FormatException('Choose a PNG or JPEG image containing a pairing QR code.');
    }
    final (width, height) = dimensions;
    if (width <= 0 || height <= 0 || width > maxDimension || height > maxDimension || width * height > maxPixels) {
      throw const FormatException('This image is too large to scan safely.');
    }

    final decoded = img.decodeImage(bytes);
    if (decoded == null || decoded.width != width || decoded.height != height) {
      throw const FormatException('The image could not be decoded.');
    }
    // RGBLuminanceSource reads each 32-bit pixel as ARGB. BGRA byte order
    // produces that value when read through Dart's little-endian Int32List.
    final pixelBytes = decoded.convert(numChannels: 4).getBytes(order: img.ChannelOrder.bgra);
    final luminance = RGBLuminanceSource(
      decoded.width,
      decoded.height,
      pixelBytes.buffer.asInt32List(pixelBytes.offsetInBytes, pixelBytes.lengthInBytes ~/ 4),
    );
    try {
      final result = QRCodeReader().decode(BinaryBitmap(HybridBinarizer(luminance)));
      if (result.text.trim().isEmpty) throw const FormatException('The QR code is empty.');
      return result.text.trim();
    } catch (exception) {
      if (exception is FormatException) rethrow;
      throw const FormatException('No readable pairing QR code was found.');
    }
  }

  (int, int)? _dimensions(Uint8List bytes) {
    if (bytes.length >= 24 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return (_u32be(bytes, 16), _u32be(bytes, 20));
    }
    if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;

    var position = 2;
    while (position + 3 < bytes.length) {
      while (position < bytes.length && bytes[position] != 0xFF) {
        position++;
      }
      while (position < bytes.length && bytes[position] == 0xFF) {
        position++;
      }
      if (position >= bytes.length) return null;
      final marker = bytes[position++];
      if (marker == 0xD9 || marker == 0xDA) return null;
      if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) continue;
      if (position + 1 >= bytes.length) return null;
      final length = (bytes[position] << 8) | bytes[position + 1];
      if (length < 2 || position + length > bytes.length) return null;
      if (_isStartOfFrame(marker)) {
        if (length < 7) return null;
        final height = (bytes[position + 3] << 8) | bytes[position + 4];
        final width = (bytes[position + 5] << 8) | bytes[position + 6];
        return (width, height);
      }
      position += length;
    }
    return null;
  }

  int _u32be(Uint8List bytes, int offset) =>
      (bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3];

  bool _isStartOfFrame(int marker) => const {
        0xC0,
        0xC1,
        0xC2,
        0xC3,
        0xC5,
        0xC6,
        0xC7,
        0xC9,
        0xCA,
        0xCB,
        0xCD,
        0xCE,
        0xCF,
      }.contains(marker);
}
