// Phase 2 (scan-throughput) benchmark harness.
//
// Measures end-to-end latency of `MRZScanner.scanImage(bytes)` on the
// static `mrzscanner_static` channel. Runs ONE cold call + N=50 warm calls
// against `integration_test/fixtures/sample_mrz.png` (a synthetic MRZ
// rendered into a high-contrast monospaced canvas; if Tesseract cannot OCR
// the synthetic sample, drop a real passport sample at the same path —
// bench still measures latency end-to-end).
//
// Run from the example app directory:
//
//   cd example && flutter test integration_test/scan_image_bench_test.dart \
//                                  --reporter=expanded
//
// (i.e. invoke from the example app so the plugin's native side is loaded.)
//
// Output:
//   - Console: a single line `== scan_image_bench == { ... json ... }`
//   - File:    build/bench/scan_image_bench.json (best-effort; some
//              sandboxes block writes)
//
// Baseline numbers (captured BEFORE the Phase 2 perf changes land) are
// recorded in `.planning/phases/02-scan-throughput/02-BASELINE.md`.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_mrz_scanner_enhanced/flutter_mrz_scanner_enhanced.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('scan_image_bench: cold + 50 warm', () async {
    final bytes = await _loadOrSynthesizeSample();

    // Cold call (includes any first-call native init cost — Tesseract init,
    // trained-data extraction, etc.).
    final coldSw = Stopwatch()..start();
    final coldResult = await MRZScanner.scanImage(bytes);
    coldSw.stop();

    // Warm calls.
    const n = 50;
    final warm = <int>[];
    for (var i = 0; i < n; i++) {
      final sw = Stopwatch()..start();
      await MRZScanner.scanImage(bytes);
      sw.stop();
      warm.add(sw.elapsedMicroseconds);
    }
    warm.sort();
    int pct(double p) {
      final idx = (warm.length * p).clamp(0, warm.length - 1).toInt();
      return warm[idx];
    }

    final p50 = pct(0.50);
    final p99 = pct(0.99);
    final mean = warm.reduce((a, b) => a + b) ~/ warm.length;
    final coldMs = coldSw.elapsedMicroseconds / 1000.0;
    final p50Ms = p50 / 1000.0;

    // Variance.
    final meanD = mean.toDouble();
    final variance =
        warm.map((v) => (v - meanD) * (v - meanD)).reduce((a, b) => a + b) /
            warm.length;
    final stddev = (variance > 0) ? _sqrt(variance) : 0.0;

    final summary = <String, dynamic>{
      'cold_ms': coldMs,
      'warm_n': n,
      'warm_min_ms': warm.first / 1000.0,
      'warm_p50_ms': p50Ms,
      'warm_p99_ms': p99 / 1000.0,
      'warm_mean_ms': mean / 1000.0,
      'warm_stddev_ms': stddev / 1000.0,
      'gap_cold_minus_p50_ms': coldMs - p50Ms,
      'cold_returned_non_null': coldResult != null,
    };
    // ignore: avoid_print
    print('== scan_image_bench == ${jsonEncode(summary)}');

    // Best-effort JSON dump.
    try {
      final dir = Directory('build/bench')..createSync(recursive: true);
      File('${dir.path}/scan_image_bench.json')
          .writeAsStringSync(jsonEncode(summary));
    } catch (_) {
      // Sandbox may block writes; ignore.
    }
    expect(warm.length, n);
  }, timeout: const Timeout(Duration(minutes: 5)));
}

Future<Uint8List> _loadOrSynthesizeSample() async {
  // Try filesystem first (committed PNG).
  final f = File('integration_test/fixtures/sample_mrz.png');
  if (f.existsSync()) {
    return f.readAsBytesSync();
  }
  // Try asset bundle (if registered under flutter assets).
  try {
    final data =
        await rootBundle.load('integration_test/fixtures/sample_mrz.png');
    return data.buffer.asUint8List();
  } catch (_) {
    // Synthesize at runtime.
    final synthesized = await _synthesizeMrzPng();
    try {
      f.parent.createSync(recursive: true);
      f.writeAsBytesSync(synthesized);
    } catch (_) {
      // Ignore.
    }
    return synthesized;
  }
}

// Renders the canonical TD3 sample (also used by test/static_channel_test.dart)
// onto a 1280x800 white canvas with a high-contrast monospaced font. This is
// NOT guaranteed to OCR cleanly with the `ocrb` traineddata (TTF Courier !=
// OCR-B), but the bench still measures end-to-end call latency.
Future<Uint8List> _synthesizeMrzPng() async {
  const w = 1280;
  const h = 800;
  const td3Line1 =
      'P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<';
  const td3Line2 = 'L898902C36UTO7408122F1204159ZE184226B<<<<<10';
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, 1280.0, 800.0));
  final paintBg = Paint()..color = const Color(0xFFFFFFFF);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 1280.0, 800.0), paintBg);
  final style = ui.TextStyle(
    color: const Color(0xFF000000),
    fontFamily: 'Courier',
    fontSize: 36.0,
    fontWeight: FontWeight.w700,
  );
  final paragraphStyle = ui.ParagraphStyle(
    textAlign: TextAlign.left,
    fontFamily: 'Courier',
    fontSize: 36.0,
  );
  final pb = ui.ParagraphBuilder(paragraphStyle)
    ..pushStyle(style)
    ..addText('$td3Line1\n$td3Line2');
  final paragraph = pb.build()..layout(const ui.ParagraphConstraints(width: 1240.0));
  canvas.drawParagraph(paragraph, const Offset(20, 360));
  final picture = recorder.endRecording();
  final image = await picture.toImage(w, h);
  final bd = await image.toByteData(format: ui.ImageByteFormat.png);
  return bd!.buffer.asUint8List();
}

double _sqrt(double v) {
  // dart:math.sqrt; kept inline-imported to avoid additional imports.
  // Use Newton-Raphson for portability without `import 'dart:math'`.
  if (v <= 0) return 0.0;
  var x = v;
  for (var i = 0; i < 20; i++) {
    x = 0.5 * (x + v / x);
  }
  return x;
}
