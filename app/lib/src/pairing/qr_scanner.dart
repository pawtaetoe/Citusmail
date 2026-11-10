// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app.dart' show appName;
import 'qr_code.dart';

/// Builds the scanner: calls [onCode] with the text of each QR code it
/// reads. Tests give one that hands over a text right away.
typedef QrScannerBuilder = Widget Function(
  BuildContext context,
  ValueChanged<String> onCode,
);

/// The camera with QR reading on the phone: CameraX for the picture
/// (no Google Play services), zxing2 (pure Dart) for reading, off the UI
/// thread. Android asks for the camera only when this opens; nothing is
/// recorded or kept, frames are read and dropped.
final class CameraQrScanner extends StatefulWidget {
  const CameraQrScanner({super.key, required this.onCode});

  final ValueChanged<String> onCode;

  static Widget build(BuildContext context, ValueChanged<String> onCode) =>
      CameraQrScanner(onCode: onCode);

  @override
  State<CameraQrScanner> createState() => _CameraQrScannerState();
}

final class _CameraQrScannerState extends State<CameraQrScanner> {
  CameraController? _camera;
  String? _problem;
  bool _reading = false;
  bool _found = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final cameras = await availableCameras();
      final back =
          cameras
              .where((c) => c.lensDirection == CameraLensDirection.back)
              .firstOrNull ??
          cameras.firstOrNull;
      if (back == null) {
        return _fail('This device has no camera $appName can use.');
      }
      final camera = CameraController(
        back,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await camera.initialize();
      if (!mounted) {
        await camera.dispose();
        return;
      }
      setState(() => _camera = camera);
      await camera.startImageStream(_onFrame);
    } on CameraException catch (e) {
      _fail(
        e.code.contains('Denied') || e.code.contains('denied')
            ? '$appName needs the camera to scan the code. Allow it in '
                  'Android\'s settings for $appName, then try again.'
            : 'The camera couldn\'t start. (${e.description ?? e.code})',
      );
    }
  }

  void _fail(String problem) {
    if (mounted) setState(() => _problem = problem);
  }

  void _onFrame(CameraImage image) {
    if (_reading || _found || image.planes.isEmpty) return;
    _reading = true;
    final y = image.planes.first;
    final frame = LuminanceFrame(
      Uint8List.fromList(y.bytes),
      image.width,
      image.height,
      y.bytesPerRow,
    );
    compute(decodeQrFrame, frame).then((text) {
      _reading = false;
      if (text == null || _found || !mounted) return;
      _found = true;
      unawaited(_camera?.stopImageStream());
      widget.onCode(text);
    });
  }

  @override
  void dispose() {
    unawaited(_camera?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final problem = _problem;
    if (problem != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(problem, textAlign: TextAlign.center),
        ),
      );
    }
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: CameraPreview(camera),
    );
  }
}
