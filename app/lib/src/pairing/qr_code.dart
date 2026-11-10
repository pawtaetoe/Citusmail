// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:zxing2/qrcode.dart';

/// A QR code's modules: true for dark.
final class QrModules {
  QrModules._(this.size, this._dark);

  /// [text] as a QR code (error correction M: survives a little glare).
  factory QrModules.encode(String text) {
    final matrix = Encoder.encode(text, ErrorCorrectionLevel.m).matrix!;
    return QrModules._(matrix.width, [
      for (var y = 0; y < matrix.height; y++)
        for (var x = 0; x < matrix.width; x++) matrix.get(x, y) == 1,
    ]);
  }

  final int size;
  final List<bool> _dark;

  bool isDark(int x, int y) => _dark[y * size + x];
}

/// A QR code, always dark on white (with the quiet zone readers need),
/// also in dark mode.
final class QrCodeView extends StatelessWidget {
  QrCodeView({super.key, required this.data, this.size = 240})
    : _modules = QrModules.encode(data);

  final String data;
  final double size;
  final QrModules _modules;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'QR code',
    image: true,
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
      ),
      child: CustomPaint(painter: _QrPainter(_modules)),
    ),
  );
}

final class _QrPainter extends CustomPainter {
  _QrPainter(this.modules);

  final QrModules modules;

  /// Modules of white around the code.
  static const _quiet = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final count = modules.size + 2 * _quiet;
    final module = size.shortestSide / count;
    final paint = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    for (var y = 0; y < modules.size; y++) {
      for (var x = 0; x < modules.size; x++) {
        if (!modules.isDark(x, y)) continue;
        canvas.drawRect(
          Rect.fromLTWH(
            (x + _quiet) * module,
            (y + _quiet) * module,
            module + 0.5,
            module + 0.5,
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.modules != modules;
}

/// One camera frame's brightness: the Y plane of a YUV image, row by row
/// ([rowStride] bytes a row, of which [width] are the picture).
final class LuminanceFrame {
  const LuminanceFrame(this.bytes, this.width, this.height, this.rowStride);

  final Uint8List bytes;
  final int width;
  final int height;
  final int rowStride;
}

final class _FrameSource extends LuminanceSource {
  _FrameSource(this.frame) : super(frame.width, frame.height);

  final LuminanceFrame frame;

  @override
  Int8List getRow(int y, Int8List? row) {
    final out = (row == null || row.length < width) ? Int8List(width) : row;
    final start = y * frame.rowStride;
    for (var x = 0; x < width; x++) {
      out[x] = frame.bytes[start + x];
    }
    return out;
  }

  @override
  Int8List getMatrix() {
    final out = Int8List(width * height);
    for (var y = 0; y < height; y++) {
      final start = y * frame.rowStride;
      for (var x = 0; x < width; x++) {
        out[y * width + x] = frame.bytes[start + x];
      }
    }
    return out;
  }
}

/// The text of a QR code in [frame], or null if none is readable. Pure
/// Dart (zxing2), so it runs off the UI thread with `compute`.
String? decodeQrFrame(LuminanceFrame frame) {
  try {
    return QRCodeReader()
        .decode(BinaryBitmap(HybridBinarizer(_FrameSource(frame))))
        .text;
  } on ReaderException {
    return null;
  } on ArgumentError {
    return null;
  }
}
