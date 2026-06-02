import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_mrz_scanner_enhanced/src/camera_overlay.dart';
import 'package:mrz_parser/mrz_parser.dart';

/// Global MethodChannel used by [MRZScanner.scanImage]. Independent of any
/// platform-view instance; registered by the plugin entrypoint on both platforms.
const MethodChannel _staticChannel = MethodChannel('mrzscanner_static');

/// Splits raw OCR text into MRZ-shaped lines, applying the same character
/// fix-ups used by the live capture path. Top-level so both [MRZController]
/// and [MRZScanner.scanImage] share one implementation.
List<String> _splitRecognized(String recognizedText) {
  final mrzString = recognizedText
      .replaceAll(' ', '')
      .replaceAll('«', '<')
      .replaceAll('DZAK', 'DZA<');
  return mrzString.split('\n').where((s) => s.isNotEmpty).toList();
}

/// MRZ scanner camera widget
class MRZScanner extends StatelessWidget {
  const MRZScanner({
    required this.onControllerCreated,
    this.withOverlay = false,
    Key? key,
  }) : super(key: key);

  /// Provides a controller for MRZ handling
  final void Function(MRZController controller) onControllerCreated;

  /// Displays MRZ scanner overlay
  final bool withOverlay;

  @override
  Widget build(BuildContext context) {
    final scanner = defaultTargetPlatform == TargetPlatform.iOS
        ? UiKitView(
            viewType: 'mrzscanner',
            onPlatformViewCreated: (int id) => onPlatformViewCreated(id),
            creationParamsCodec: const StandardMessageCodec(),
          )
        : defaultTargetPlatform == TargetPlatform.android
            ? AndroidView(
                viewType: 'mrzscanner',
                onPlatformViewCreated: (int id) => onPlatformViewCreated(id),
                creationParamsCodec: const StandardMessageCodec(),
              )
            : Text('$defaultTargetPlatform is not supported by this plugin');
    return withOverlay ? CameraOverlay(child: scanner) : scanner;
  }

  void onPlatformViewCreated(int id) {
    final controller = MRZController._init(id);
    onControllerCreated(controller);
  }

  /// Scan a still image's bytes for an MRZ. Reuses the same Tesseract pipeline
  /// as the live camera path via the global `mrzscanner_static` channel.
  ///
  /// Returns:
  /// - a [MRZFullResult] when OCR + parse succeed,
  /// - `null` when OCR finds nothing or the recognized text is not a valid MRZ.
  ///
  /// Throws [PlatformException] on native decode/scan failure.
  static Future<MRZFullResult?> scanImage(Uint8List bytes) async {
    final raw = await _staticChannel.invokeMethod<String>(
      'scanImage',
      <String, dynamic>{'bytes': bytes},
    );
    if (raw == null) return null;
    final lines = _splitRecognized(raw);
    if (lines.isEmpty) return null;
    final parsed = MRZParser.tryParse(lines);
    if (parsed == null) return null;
    return MRZFullResult(mrz: raw, mrzResult: parsed);
  }
}

class MRZController {
  MRZController._init(int id) {
    _channel = MethodChannel('mrzscanner_$id');
    _channel.setMethodCallHandler(_platformCallHandler);
  }

  late final MethodChannel _channel;

  void Function()? onDetection;
  void Function(MRZFullResult mrz)? onParsed;
  void Function(String text)? onError;
  void Function()? onParsingFailed;

  /// Watchdog for the "scanning but never finds an MRZ" hang: if neither a
  /// successful parse ([onParsed]) nor a native [onError] arrives within the
  /// timeout passed to [startPreview], [onError] is fired once so the UI can
  /// surface a retry/fallback instead of sitting on "Scanning…" forever.
  /// Note: [onParsingFailed] fires on every non-MRZ frame and deliberately
  /// does NOT reset this timer — the watchdog measures wall-clock time, not
  /// per-frame parse attempts.
  Timer? _watchdog;

  void _startWatchdog(Duration timeout) {
    _watchdog?.cancel();
    if (timeout <= Duration.zero) {
      return; // opt-out: no watchdog
    }
    _watchdog = Timer(timeout, () {
      _watchdog = null;
      onError?.call(
        'No MRZ detected within ${timeout.inSeconds}s. Scan timed out.',
      );
    });
  }

  void _cancelWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
  }

  void flashlightOn() {
    _channel.invokeMethod<void>('flashlightOn');
  }

  void flashlightOff() {
    _channel.invokeMethod<void>('flashlightOff');
  }

  Future<List<int>?> takePhoto({bool crop = true}) async {
    final result = await _channel.invokeMethod<List<int>>(
      'takePhoto',
      {
        'crop': crop,
      },
    );
    return result;
  }

  Future<void> _platformCallHandler(MethodCall call) {
    switch (call.method) {
      case 'onError':
        _cancelWatchdog();
        onError?.call(call.arguments);
        debugPrint('Error occurred: ${call.arguments}');
        break;
      case 'onParsed':
        if (onParsed != null) {
          debugPrint('MRZ detected, parsing please wait...');
          onDetection?.call(); // Notify that MRZ is detected
          final String filePath = call.arguments as String;
          debugPrint('MRZ BEFORE PARSE: $filePath');
          final lines = _splitRecognized(call.arguments);
          if (lines.isNotEmpty) {
            final result = MRZParser.tryParse(lines);
            if (result != null) {
              // Terminal success — stop the no-result watchdog before
              // handing the result to the consumer.
              _cancelWatchdog();
              onParsed!(MRZFullResult(mrz: filePath, mrzResult: result));
              debugPrint('Parsing successful');
            } else {
              debugPrint('Parsing failed, Scanning again');
              onParsingFailed?.call(); // Notify parsing failure
            }
          } else {
            debugPrint('No MRZ lines detected');
            onParsingFailed?.call(); // Notify parsing failure
          }
        }
        break;
    }
    return Future.value();
  }

  /// Starts the live camera preview.
  ///
  /// [scanTimeout] arms a watchdog (see [_watchdog]); if no MRZ is read within
  /// it, [onError] fires once. Defaults to 25s — long enough for slow scans
  /// (poor light, cold OCR start, repositioning), short enough to unblock a
  /// stuck user. Pass [Duration.zero] to disable the watchdog entirely.
  void startPreview({
    bool isFrontCam = false,
    Duration scanTimeout = const Duration(seconds: 25),
  }) {
    _channel.invokeMethod<void>('start', {'isFrontCam': isFrontCam});
    _startWatchdog(scanTimeout);
  }

  void stopPreview() {
    _cancelWatchdog();
    _channel.invokeMethod<void>('stop');
  }

  /// Releases the watchdog timer. Call from the host widget's `dispose()` so a
  /// pending timer cannot fire [onError] after the consumer is gone.
  void dispose() {
    _cancelWatchdog();
  }
}

class MRZFullResult {
  MRZFullResult({required this.mrz, required this.mrzResult});
  final String mrz;
  final MRZResult mrzResult;
}
