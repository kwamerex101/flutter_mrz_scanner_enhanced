---
phase: 02-scan-throughput
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - integration_test/scan_image_bench_test.dart
  - integration_test/fixtures/sample_mrz.png
  - example/pubspec.yaml
  - example/integration_test/plugin_integration_test.dart
  - pubspec.yaml
  - android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/MrzOcr.kt
  - android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FotoapparatCamera.kt
  - android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FlutterMrzScannerPlugin.kt
  - ios/Classes/MRZScannerView.swift
  - ios/Classes/MrzImageOcr.swift
  - .planning/phases/02-scan-throughput/02-BASELINE.md
autonomous: false
requirements:
  - PERF-01
  - PERF-02
  - PERF-03

must_haves:
  truths:
    - "Tesseract is initialized at most once per scanning session on both platforms (live owns its own TessBaseAPI; static keeps a process-wide shared TessBaseAPI on Android; iOS SwiftyTesseract already lazy)."
    - "Cached TessBaseAPI is recycled when the camera is torn down (no native-resource leak); MRZScannerView.dispose() now calls cameraView.dispose()."
    - "Live frame loop drops frames while OCR is in flight on both platforms — no coroutine/dispatch backlog accumulates under sustained load."
    - "Android live path no longer encodes YUV → JPEG just to decode back to a Bitmap; conversion goes directly from the NV21 Y-plane to a thresholded ARGB_8888 Bitmap."
    - "iOS reuses one VNDetectTextRectanglesRequest across frames, and one shared CIContext across all preprocess calls."
    - "iOS takePhoto skips the resize pass when the image is already within 720×1280, and skips the EXIF rotation draw when orientation is .up."
    - "Phase 1 contract is intact: MethodChannel('mrzscanner_static').invokeMethod('scanImage', {'bytes': bytes}) still works; test/static_channel_test.dart still passes (3/3)."
    - "A benchmark exists that records cold + warm latencies for the static scanImage path; baseline numbers are captured BEFORE optimization tasks land and after-numbers are captured at the end of the phase."
  artifacts:
    - path: "integration_test/scan_image_bench_test.dart"
      provides: "Static-path benchmark measuring cold + warm (n=50) MRZScanner.scanImage latency; emits console table + build/bench/scan_image_bench.json."
      contains: "scan_image_bench"
    - path: ".planning/phases/02-scan-throughput/02-BASELINE.md"
      provides: "Recorded baseline numbers (cold, p50, p99, mean, gap) captured BEFORE Tesseract caching lands."
      contains: "BASELINE"
    - path: "android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/MrzOcr.kt"
      provides: "acquireSharedBaseApi(context) + runTesseractWith(api, bitmap) + a synchronized lock over setImage/utF8Text on the shared static-path API."
      contains: "acquireSharedBaseApi"
    - path: "android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FotoapparatCamera.kt"
      provides: "Per-session TessBaseAPI owned by FotoapparatCamera; AtomicBoolean ocrInFlight throttle; nv21ToBinaryBitmap helper; dispose() recycles cached API."
      contains: "ocrInFlight"
    - path: "android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FlutterMrzScannerPlugin.kt"
      provides: "MRZScannerView.dispose() now calls cameraView.dispose() so the cached TessBaseAPI is recycled on camera teardown."
      contains: "cameraView.dispose()"
    - path: "ios/Classes/MRZScannerView.swift"
      provides: "Stored lazy VNDetectTextRectanglesRequest; DispatchSemaphore drop-while-busy throttle; conditional resize + EXIF early-return in takePhoto."
      contains: "ocrSemaphore"
    - path: "ios/Classes/MrzImageOcr.swift"
      provides: "static let sharedCIContext shared across all preprocess calls; comment asserting the existing lazy-tesseract reuse property."
      contains: "sharedCIContext"
  key_links:
    - from: "FotoapparatCamera.processFrame"
      to: "AtomicBoolean ocrInFlight + cached TessBaseAPI"
      via: "compareAndSet gate before preprocessing; runTesseractWith(tessApi, bitmap) reuses cached API; finally sets flag false"
      pattern: "ocrInFlight\\.compareAndSet"
    - from: "FotoapparatCamera live OCR path"
      to: "nv21ToBinaryBitmap(frame)"
      via: "direct Y-plane → thresholded ARGB_8888 Bitmap; no YuvImage / compressToJpeg / decodeByteArray"
      pattern: "nv21ToBinaryBitmap"
    - from: "FlutterMrzScannerPlugin.handleScanImage"
      to: "MrzOcr.acquireSharedBaseApi(ctx) + synchronized(baseApiLock) { setImage; utF8Text }"
      via: "shared static-path TessBaseAPI; concurrent Thread { ... }.start() callers serialized at the lock"
      pattern: "acquireSharedBaseApi|baseApiLock"
    - from: "MRZScannerView.captureOutput"
      to: "self.textDetectionRequest (lazy stored property) + ocrSemaphore.wait(timeout: .now())"
      via: "tryWait gate; OCR work moved to ocrQueue; defer signal; reused VNDetectTextRectanglesRequest"
      pattern: "textDetectionRequest|ocrSemaphore"
    - from: "MrzImageOcr.preprocess"
      to: "Self.sharedCIContext"
      via: "static let on the class; replaces per-call CIContext(options: nil)"
      pattern: "sharedCIContext"
    - from: "MRZScannerView.dispose() (Android Kotlin)"
      to: "cameraView.dispose() → tessApi?.recycle()"
      via: "lifecycle wiring; closes pre-existing job-leak AND recycles cached TessBaseAPI"
      pattern: "cameraView\\.dispose\\(\\)"
---

<objective>
Make the MRZ scan path materially faster on both platforms without changing the
public Dart/MethodChannel API. Three structural wins: cache `TessBaseAPI` per
session (Android live + Android static + verify on iOS), drop frames while OCR
is in flight (both platforms), eliminate the YUV→JPEG→Bitmap roundtrip on
Android. Plus four iOS quick wins (reused `VNDetectTextRectanglesRequest`,
shared `CIContext`, conditional resize in `takePhoto`, conditional EXIF in
`takePhoto`). A benchmark scaffolds the phase so wins are provable.

Purpose: deliver PERF-01 / PERF-02 / PERF-03 from REQUIREMENTS.md without
regressing the SCAN-IMG-* contract from Phase 1.

Output:
- `integration_test/scan_image_bench_test.dart` + a recorded `02-BASELINE.md`.
- A cached, lock-protected `TessBaseAPI` in both Android paths; recycled on
  camera teardown via a fixed `MRZScannerView.dispose()`.
- A `drop-while-busy` throttle on both platforms.
- A pure-Kotlin `nv21ToBinaryBitmap` replacing `getImage` + `preprocessImage`.
- Reused `VNDetectTextRectanglesRequest` and `CIContext` on iOS, plus
  `takePhoto` resize/EXIF early-returns.
- A re-run benchmark with after-numbers in the phase SUMMARY.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/REQUIREMENTS.md
@.planning/ROADMAP.md
@.planning/phases/02-scan-throughput/02-CONTEXT.md
@.planning/phases/02-scan-throughput/02-RESEARCH.md
@.planning/phases/01-image-based-mrz-scan/01-PLAN.md

@android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/MrzOcr.kt
@android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FotoapparatCamera.kt
@android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FlutterMrzScannerPlugin.kt
@ios/Classes/MRZScannerView.swift
@ios/Classes/MrzImageOcr.swift
@ios/Classes/SwiftFlutterMrzScannerPlugin.swift
@lib/src/mrz_scanner.dart
@test/static_channel_test.dart

<interfaces>
<!-- Contracts the executor MUST preserve -->

Dart (Phase 1, must remain byte-identical):
```dart
class MRZScanner {
  static Future<MRZFullResult?> scanImage(Uint8List bytes);  // unchanged
}
const MethodChannel _staticChannel = MethodChannel('mrzscanner_static');  // unchanged
// invokeMethod<String?>('scanImage', {'bytes': bytes})
```

Android — current MrzOcr surface (object):
```kotlin
object MrzOcr {
  fun ensureTrainedData(context: Context)
  fun scanImage(context: Context, bytes: ByteArray): String?   // existing static-path entrypoint; keep signature
  fun preprocess(bitmap: Bitmap): Bitmap                       // keep
  internal fun runTesseract(context: Context, bitmap: Bitmap): String?  // keep + new overload added
}
```

New Android additions (this phase):
```kotlin
object MrzOcr {
  // static-path shared API (app-lifetime; never recycled)
  internal fun acquireSharedBaseApi(context: Context): TessBaseAPI
  internal val baseApiLock: Any
  // overload that reuses a caller-owned API; live path uses this
  internal fun runTesseractWith(api: TessBaseAPI, bitmap: Bitmap): String?
}
```

FotoapparatCamera new fields:
```kotlin
private var tessApi: TessBaseAPI? = null
private val tessLock = Any()
private val ocrInFlight = java.util.concurrent.atomic.AtomicBoolean(false)
private fun ensureTessApi(): TessBaseAPI  // double-checked locking
fun dispose() // extended: cancel job + recycle tessApi under tessLock
private fun nv21ToBinaryBitmap(frame: Frame, threshold: Int = 128): Bitmap
```

iOS — new surface:
```swift
final class MrzImageOcr {
  static let sharedCIContext = CIContext(options: nil)  // new
  // tesseract: lazy var (already cached — confirm + comment)
}

class MRZScannerView {
  private lazy var textDetectionRequest: VNDetectTextRectanglesRequest = { ... }()
  private let ocrSemaphore = DispatchSemaphore(value: 1)
  private let ocrQueue = DispatchQueue(label: "mrz_ocr_queue", qos: .userInitiated)
}
```

Tesseract4Android API used (verified in research, see RESEARCH.md §"API confirmation"):
- `TessBaseAPI()` + `init(dataPath, "ocrb")` + `setVariable(..., whitelist)` + `pageSegMode = PSM_SINGLE_BLOCK` are all callable ONCE per cached instance.
- `setImage(Bitmap)` + `utF8Text` may be called repeatedly afterward.
- `recycle()` releases native resources; instance unusable after.

Phase 1 unit test contract (test/static_channel_test.dart) — refactors MUST NOT touch:
- channel name `mrzscanner_static`
- method name `scanImage`
- args shape `{'bytes': Uint8List}`
- return type `String?` (raw recognized text)
</interfaces>
</context>

<tasks>

<!-- ============================================================
     TASK 1 — Benchmark scaffolding + baseline capture (FIRST)
     ============================================================ -->
<task type="auto" tdd="false">
  <name>Task 1: Benchmark harness for static scanImage; record baseline numbers BEFORE any perf changes</name>
  <files>
    integration_test/scan_image_bench_test.dart (new),
    integration_test/fixtures/sample_mrz.png (new — generated synthetic MRZ),
    example/pubspec.yaml (modify — add integration_test dev_dep),
    example/integration_test/plugin_integration_test.dart (new — runner harness if needed for the example app),
    pubspec.yaml (modify — add integration_test under dev_dependencies),
    .planning/phases/02-scan-throughput/02-BASELINE.md (new)
  </files>
  <behavior>
    - `flutter test integration_test/scan_image_bench_test.dart` (run from `example/` so the plugin native side is loaded) executes a cold call + N=50 warm calls of `MRZScanner.scanImage(bytes)` against a bundled `sample_mrz.png`.
    - Reports cold latency (ms), warm min / p50 / p99 / mean / stddev, and `gap = cold - p50_warm`.
    - Writes machine-readable JSON to `build/bench/scan_image_bench.json`.
    - Writes a human-readable line to test stdout (captured in `02-BASELINE.md` by the operator).
    - Falls back gracefully if the synthetic PNG cannot be OCR'd by Tesseract: bench still runs, reports "OCR returned null on sample" but still measures call latency end-to-end.
    - Does NOT change any production code under `lib/`, `android/`, or `ios/` — this task is purely additive scaffolding.
  </behavior>
  <action>
    1. Add `integration_test:` to `pubspec.yaml` `dev_dependencies` (use `sdk: flutter`). Add the same to `example/pubspec.yaml` under `dev_dependencies` so the example can run integration tests.
    2. Create `integration_test/fixtures/sample_mrz.png`:
       - Decision per RESEARCH §"Sample image" (option a synthetic; option c fallback): use a synthetic. Generate at FIRST invocation of the bench if the file is absent — render the canonical TD3 fixture from `test/static_channel_test.dart` ("P<UTOERIKSSON<<ANNA<MARIA..." / "L898902C36UTO7408122F1204159ZE184226B<<<<<10") onto a 1280×800 Flutter `Canvas` using a high-contrast monospaced font (`TextStyle(fontFamily: 'Courier', fontSize: 32, color: Colors.black)` on white). Encode via `image.toByteData(format: ImageByteFormat.png)` and write to disk via `dart:io`. If `flutter test` integration sandbox blocks file writes, generate in-memory and skip the disk fallback.
       - If the synthetic PNG fails to OCR (Tesseract returns null/blank with `ocrb` traineddata on TTF-rendered text), document in the bench output and add a code comment instructing operators to drop a real passport sample at this path; bench continues to measure latency.
       - Add the fixtures directory to `flutter:` `assets:` in `pubspec.yaml` IF the bench loads it via `rootBundle`; if it loads via `dart:io` from the integration_test working directory, no asset registration is needed.
    3. Create `integration_test/scan_image_bench_test.dart`:
       ```dart
       import 'dart:convert';
       import 'dart:io';
       import 'dart:typed_data';
       import 'package:flutter/services.dart';
       import 'package:flutter_test/flutter_test.dart';
       import 'package:integration_test/integration_test.dart';
       import 'package:flutter_mrz_scanner_enhanced/flutter_mrz_scanner_enhanced.dart';

       void main() {
         IntegrationTestWidgetsFlutterBinding.ensureInitialized();

         test('scan_image_bench: cold + 50 warm', () async {
           final bytes = await _loadOrSynthesizeSample();
           // Cold
           final coldSw = Stopwatch()..start();
           final coldResult = await MRZScanner.scanImage(bytes);
           coldSw.stop();
           // Warm
           const n = 50;
           final warm = <int>[];
           for (var i = 0; i < n; i++) {
             final sw = Stopwatch()..start();
             await MRZScanner.scanImage(bytes);
             sw.stop();
             warm.add(sw.elapsedMicroseconds);
           }
           warm.sort();
           int pct(double p) => warm[(warm.length * p).clamp(0, warm.length - 1).toInt()];
           final p50 = pct(0.50);
           final p99 = pct(0.99);
           final mean = warm.reduce((a, b) => a + b) ~/ warm.length;
           final coldMs = coldSw.elapsedMicroseconds / 1000.0;
           final p50Ms = p50 / 1000.0;
           final summary = {
             'cold_ms': coldMs,
             'warm_n': n,
             'warm_min_ms': warm.first / 1000.0,
             'warm_p50_ms': p50Ms,
             'warm_p99_ms': p99 / 1000.0,
             'warm_mean_ms': mean / 1000.0,
             'gap_cold_minus_p50_ms': coldMs - p50Ms,
             'cold_returned_non_null': coldResult != null,
           };
           // Print human-readable line
           // ignore: avoid_print
           print('== scan_image_bench == ${jsonEncode(summary)}');
           // Write JSON (best-effort; some sandboxes block writes)
           try {
             final dir = Directory('build/bench')..createSync(recursive: true);
             File('${dir.path}/scan_image_bench.json')
                 .writeAsStringSync(jsonEncode(summary));
           } catch (_) {}
           expect(warm.length, n);
         }, timeout: const Timeout(Duration(minutes: 5)));
       }

       Future<Uint8List> _loadOrSynthesizeSample() async {
         // Try filesystem first
         final f = File('integration_test/fixtures/sample_mrz.png');
         if (f.existsSync()) return f.readAsBytesSync();
         // Fall back to asset bundle
         final data = await rootBundle.load('integration_test/fixtures/sample_mrz.png');
         return data.buffer.asUint8List();
       }
       ```
    4. Run the bench ONCE to capture baseline (operator runs `cd example && flutter test integration_test/scan_image_bench_test.dart` on a connected device or emulator).
    5. Create `.planning/phases/02-scan-throughput/02-BASELINE.md` with the exact numbers from step 4. Template:
       ```
       # Phase 2 Baseline (pre-optimization)

       Captured: <date>
       Device: <model + OS>
       Sample: integration_test/fixtures/sample_mrz.png (synthetic | user-supplied)

       cold_ms: <X>
       warm_n: 50
       warm_min_ms: <X>
       warm_p50_ms: <X>
       warm_p99_ms: <X>
       warm_mean_ms: <X>
       gap_cold_minus_p50_ms: <X>
       cold_returned_non_null: <true|false>
       ```
       After the phase ships, after-numbers go in `02-01-SUMMARY.md` for direct comparison.
    6. **CRITICAL ORDERING:** This task MUST land (and the baseline numbers MUST be recorded in `02-BASELINE.md`) BEFORE Tasks 2-7 land. The executor must commit Task 1 + run the bench + commit `02-BASELINE.md` before starting Task 2.
  </action>
  <verify>
    <automated>cd example && flutter test integration_test/scan_image_bench_test.dart --reporter=expanded</automated>
  </verify>
  <done>
    Bench runs end-to-end on a real device/emulator. `02-BASELINE.md` has concrete numbers (not placeholders). `build/bench/scan_image_bench.json` exists. `flutter test test/static_channel_test.dart` still 3/3 green (no Phase 1 regression from the harness).
  </done>
</task>

<!-- ============================================================
     TASK 2 — Android Tesseract caching + concurrency lock + dispose-leak fix
     ============================================================ -->
<task type="auto" tdd="false">
  <name>Task 2: Android cached TessBaseAPI (live + static) + lock + recycle on dispose</name>
  <files>
    android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/MrzOcr.kt (modify),
    android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FotoapparatCamera.kt (modify),
    android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FlutterMrzScannerPlugin.kt (modify)
  </files>
  <behavior>
    - Live frame OCR no longer creates / inits / recycles a `TessBaseAPI` per frame. `FotoapparatCamera` owns ONE instance, lazily inited on first OCR call, recycled in `dispose()`.
    - Static-path OCR (`MrzOcr.scanImage`) uses a process-wide shared `TessBaseAPI` lazily inited on first call. Concurrent callers (the existing `Thread { ... }.start()` per call in `FlutterMrzScannerPlugin.handleScanImage`) are serialized by `synchronized(MrzOcr.baseApiLock) { setImage; utF8Text }`.
    - The shared static-path API is NEVER recycled (app-lifetime cache, per CONTEXT.md decision).
    - `MRZScannerView.dispose()` (in `FlutterMrzScannerPlugin.kt`) now calls BOTH `cameraView.fotoapparat.stop()` AND `cameraView.dispose()`, fixing the pre-existing coroutine-job leak AND ensuring the live-path `TessBaseAPI` is recycled.
    - Public Dart contract unchanged. `test/static_channel_test.dart` still 3/3.
    - Live and static paths use SEPARATE `TessBaseAPI` instances (per CONTEXT.md). Documented in code comments to discourage future "simplification".
  </behavior>
  <action>
    Per RESEARCH.md §"Tesseract caching plan" (lines 65-108) + §"Concurrency / thread-safety" (lines 404-420) + Pitfall P6 (line 449):

    `MrzOcr.kt`:
      - Add fields:
        ```kotlin
        @Volatile private var sharedBaseApi: TessBaseAPI? = null
        internal val baseApiLock = Any()
        ```
      - Add:
        ```kotlin
        internal fun acquireSharedBaseApi(context: Context): TessBaseAPI {
            sharedBaseApi?.let { return it }
            ensureTrainedData(context)
            synchronized(baseApiLock) {
                sharedBaseApi?.let { return it }
                val api = TessBaseAPI()
                api.init(context.cacheDir.absolutePath, TESS_LANG)
                api.setVariable("tessedit_char_whitelist", TESS_WHITELIST)
                api.pageSegMode = PAGE_SEG_MODE
                sharedBaseApi = api
                return api
            }
        }

        /**
         * Reuse-friendly OCR: caller owns [api]; we only setImage + read text.
         * Caller must serialize concurrent calls on [api] externally
         * (live path is single-frame-thread; static path uses [baseApiLock]).
         */
        internal fun runTesseractWith(api: TessBaseAPI, bitmap: Bitmap): String? {
            api.setImage(bitmap)
            val text = api.utF8Text
            return if (text.isNullOrBlank()) null else text
        }
        ```
      - Refactor existing `scanImage(context, bytes)` (`MrzOcr.kt:54-70`): replace the call to `runTesseract(context, processed)` with:
        ```kotlin
        val api = acquireSharedBaseApi(context)
        val text = synchronized(baseApiLock) { runTesseractWith(api, processed) }
        ```
      - LEAVE the existing `runTesseract(context, bitmap)` (lines 101-117) in place — no callers remain after this phase, but keep it deprecated rather than deleting to minimize blast radius. Add `@Deprecated("Use acquireSharedBaseApi + runTesseractWith")` annotation. (Or delete if a grep confirms zero callers post-refactor — verify with `grep -rn "MrzOcr.runTesseract\\b" android/`).
      - Add a code comment ABOVE `acquireSharedBaseApi`:
        ```kotlin
        // NOTE: This singleton API is the static-path cache (app-lifetime).
        // The live camera path (FotoapparatCamera.tessApi) owns its OWN
        // TessBaseAPI keyed to the camera session. Do NOT collapse them — see
        // .planning/phases/02-scan-throughput/02-CONTEXT.md.
        ```

    `FotoapparatCamera.kt`:
      - Add fields near line 33 (next to `job`/`scope`):
        ```kotlin
        private var tessApi: TessBaseAPI? = null
        private val tessLock = Any()
        ```
      - Add:
        ```kotlin
        private fun ensureTessApi(): TessBaseAPI {
            tessApi?.let { return it }
            synchronized(tessLock) {
                tessApi?.let { return it }
                MrzOcr.ensureTrainedData(context)
                val api = TessBaseAPI()
                api.init(context.cacheDir.absolutePath, "ocrb")
                api.setVariable("tessedit_char_whitelist",
                    "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789<")
                api.pageSegMode = TessBaseAPI.PageSegMode.PSM_SINGLE_BLOCK
                tessApi = api
                return api
            }
        }
        ```
      - Replace body of `scanMRZ(bitmap)` (lines 216-218) with:
        ```kotlin
        private fun scanMRZ(bitmap: Bitmap): String {
            val api = ensureTessApi()
            // Live frame queue is serial; no external lock needed.
            return MrzOcr.runTesseractWith(api, bitmap) ?: ""
        }
        ```
      - Extend `dispose()` (lines 321-323):
        ```kotlin
        fun dispose() {
            job.cancel()
            synchronized(tessLock) {
                try { tessApi?.recycle() } catch (_: Throwable) {}
                tessApi = null
            }
        }
        ```

    `FlutterMrzScannerPlugin.kt`:
      - Modify `MRZScannerView.dispose()` (lines 93-95) — fix pre-existing leak (RESEARCH.md Pitfall P6 line 449):
        ```kotlin
        override fun dispose() {
            cameraView.fotoapparat.stop()
            cameraView.dispose()  // recycles cached TessBaseAPI + cancels coroutine job
        }
        ```

    Atomic commit message:
      `perf(02-02): cache TessBaseAPI per session on Android; lock static path; fix MRZScannerView dispose leak`
  </action>
  <verify>
    <automated>cd example && flutter test ../test/static_channel_test.dart && cd android && ./gradlew :app:assembleDebug</automated>
  </verify>
  <done>
    `grep -n "TessBaseAPI()" android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/` shows exactly TWO direct constructions: one in `MrzOcr.acquireSharedBaseApi`, one in `FotoapparatCamera.ensureTessApi`. The deprecated `MrzOcr.runTesseract` either has zero callers or is removed. `MRZScannerView.dispose()` calls `cameraView.dispose()`. Phase 1 unit test 3/3 green. Android example builds. Parallelizable: NO (Tasks 3 + 5 modify the same files).
  </done>
</task>

<!-- ============================================================
     TASK 3 — Android frame throttling (drop-while-busy)
     ============================================================ -->
<task type="auto" tdd="false">
  <name>Task 3: Android AtomicBoolean ocrInFlight; processFrame early-returns when busy</name>
  <files>
    android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FotoapparatCamera.kt (modify)
  </files>
  <behavior>
    - Under sustained load, `processFrame` returns immediately when a previous OCR is still in flight; coroutine count and memory stay flat.
    - The most-recent successfully-OCR'd frame still wins (no queueing).
    - Live path callback `onParsed` still fires correctly when OCR completes.
    - When `compareAndSet` fails, NO bitmap is allocated AND NO preprocessing runs (cost gate is BEFORE the per-pixel work, per RESEARCH.md lines 142-152).
  </behavior>
  <action>
    `FotoapparatCamera.kt`:
      - Add field near line 33 (after `tessApi` / `tessLock` from Task 2):
        ```kotlin
        private val ocrInFlight = java.util.concurrent.atomic.AtomicBoolean(false)
        ```
      - Refactor `processFrame` (lines 175-193) per RESEARCH.md lines 142-152:
        ```kotlin
        private fun processFrame(frame: Frame) {
            if (!ocrInFlight.compareAndSet(false, true)) return
            val processedBitmap: Bitmap = try {
                val bitmap = getImage(frame)                          // (replaced in Task 5)
                val cropped = calculateCutoutRectCardSize(bitmap, true)
                preprocessImage(cropped)
            } catch (t: Throwable) {
                ocrInFlight.set(false)
                throw t
            }
            scope.launch {
                try {
                    val mrzText = scanMRZ(processedBitmap)
                    val fixedMrz = extractMRZ(mrzText)
                    withContext(Dispatchers.Main) {
                        messenger.invokeMethod("onParsed", fixedMrz)
                    }
                } finally {
                    try { processedBitmap.recycle() } catch (_: Throwable) {}
                    ocrInFlight.set(false)
                }
            }
        }
        ```
      - Note: the `processedBitmap.recycle()` call is new — the previous code didn't recycle it. This is correct per RESEARCH.md Pitfall P2 (`setImage` copies pixels; bitmap can be recycled after `utF8Text`). With the cached `TessBaseAPI` from Task 2, native heap pressure matters more — recycle defensively.

    Atomic commit message:
      `perf(02-03): drop frames while OCR in flight on Android (AtomicBoolean gate before preprocess)`
  </action>
  <verify>
    <automated>cd example && cd android && ./gradlew :app:assembleDebug</automated>
  </verify>
  <done>
    `grep -n "ocrInFlight" android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FotoapparatCamera.kt` shows: one field declaration + one `compareAndSet(false, true)` + one `set(false)` (in finally) + one `set(false)` (in catch). Build is green. Live camera path observably smoother under sustained scanning when manually verified in Task 8.
  </done>
</task>

<!-- ============================================================
     TASK 4 — iOS frame throttling (DispatchSemaphore + ocrQueue)
     ============================================================ -->
<task type="auto" tdd="false">
  <name>Task 4: iOS DispatchSemaphore drop-while-busy; OCR moved off the frame queue</name>
  <files>
    ios/Classes/MRZScannerView.swift (modify)
  </files>
  <behavior>
    - Under sustained load, `captureOutput` skips frames whose OCR would queue behind an in-flight one. The frame queue is no longer blocked by Vision + Tesseract work; preview stays smooth.
    - When OCR completes, `delegate?.onParse(...)` still fires on the same path it does today.
    - Reused `VNDetectTextRectanglesRequest` is safe because both the frame intake (serial `video_frames_queue`) AND the new `ocrQueue` (serial) ensure non-concurrent access (RESEARCH.md §"Vision request thread-safety" line 437).
  </behavior>
  <action>
    `MRZScannerView.swift`:
      - Add stored properties near line 19 (alongside `isScanningPaused`):
        ```swift
        private let ocrSemaphore = DispatchSemaphore(value: 1)
        private let ocrQueue = DispatchQueue(label: "mrz_ocr_queue", qos: .userInitiated)
        // Reused across frames; safe because both video_frames_queue and ocrQueue are serial.
        private lazy var textDetectionRequest: VNDetectTextRectanglesRequest = {
            let r = VNDetectTextRectanglesRequest()
            r.reportCharacterBoxes = false
            return r
        }()
        ```
      - Refactor `captureOutput` (lines 287-326) per RESEARCH.md lines 162-178 + §"VNDetectTextRectanglesRequest reuse" Option A (lines 257-271):
        ```swift
        public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard ocrSemaphore.wait(timeout: .now()) == .success else { return }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                  let cgImage = pixelBuffer.cgImage else {
                ocrSemaphore.signal()
                return
            }
            let documentImage = self.documentImage(from: cgImage)
            ocrQueue.async { [weak self] in
                guard let self = self else { return }
                defer { self.ocrSemaphore.signal() }
                let imageRequestHandler = VNImageRequestHandler(cgImage: documentImage, options: [:])
                do {
                    try imageRequestHandler.perform([self.textDetectionRequest])
                } catch {
                    return
                }
                guard let results = self.textDetectionRequest.results as? [VNTextObservation] else { return }
                let imageWidth = CGFloat(documentImage.width)
                let imageHeight = CGFloat(documentImage.height)
                let transform = CGAffineTransform.identity.scaledBy(x: imageWidth, y: -imageHeight).translatedBy(x: 0, y: -1)
                let mrzTextRectangles = results.map({ $0.boundingBox.applying(transform) }).filter({ $0.width > (imageWidth * 0.8) })
                let mrzRegionRect = mrzTextRectangles.reduce(into: CGRect.null, { $0 = $0.union($1) })
                guard mrzRegionRect.height <= (imageHeight * 0.4) else { return }
                if let mrzTextImage = documentImage.cropping(to: mrzRegionRect),
                   let mrzResult = self.mrz(from: mrzTextImage) {
                    DispatchQueue.main.async { self.delegate?.onParse(mrzResult) }
                }
            }
        }
        ```
      - Move `delegate?.onParse(mrzResult)` onto the main queue — this matches Phase 1 contract behavior (callbacks on main thread). If today's behavior delivered on the frame queue, this is a slight improvement and unlikely to break callers.

    Atomic commit message:
      `perf(02-04): iOS drop-while-busy semaphore; move OCR off frame queue; reuse VNDetectTextRectanglesRequest`
  </action>
  <verify>
    <automated>cd example/ios && pod install && xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Debug -sdk iphonesimulator -quiet build CODE_SIGNING_ALLOWED=NO</automated>
  </verify>
  <done>
    `grep -n "ocrSemaphore\\|textDetectionRequest" ios/Classes/MRZScannerView.swift` shows the stored properties, exactly one `wait(timeout: .now())` call, and exactly one `signal()` deferred. iOS example builds for simulator. Parallelizable with Task 6 (different files); NOT parallelizable with Task 5 (Task 5 also touches `MRZScannerView.swift`'s `captureOutput` indirectly).
  </done>
</task>

<!-- ============================================================
     TASK 5 — Android NV21 direct grayscale path
     ============================================================ -->
<task type="auto" tdd="false">
  <name>Task 5: Replace YUV→JPEG→Bitmap roundtrip with nv21ToBinaryBitmap (Y-plane direct)</name>
  <files>
    android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FotoapparatCamera.kt (modify)
  </files>
  <behavior>
    - Live frame conversion no longer calls `YuvImage(...).compressToJpeg(rect, 100, ...)` followed by `BitmapFactory.decodeByteArray`. Instead, NV21 Y-plane bytes are read directly into an `IntArray`, thresholded against 128 (matching `MrzOcr.preprocess`'s threshold per RESEARCH.md line 244), rotated to upright via index math, and written to a single `ARGB_8888` Bitmap.
    - OCR accuracy is preserved (threshold matches existing 128).
    - Defensive guard: if `frame.image.size != width*height*3/2` (unexpected stride / padding — RESEARCH.md Pitfall P4 line 447), the helper falls back to the OLD JPEG path and logs a warning.
    - Cropping (`calculateCutoutRectCardSize`) still happens — applied AFTER the Y→bitmap conversion (per RESEARCH.md option 2, line 236).
  </behavior>
  <action>
    `FotoapparatCamera.kt`:
      - Add `private fun nv21ToBinaryBitmap(frame: Frame, threshold: Int = 128): Bitmap` per RESEARCH.md lines 195-229. Verbatim implementation:
        ```kotlin
        private fun nv21ToBinaryBitmap(frame: Frame, threshold: Int = 128): Bitmap {
            val w = frame.size.width
            val h = frame.size.height
            val expected = w * h * 3 / 2
            // Defensive: if buffer is smaller than expected, fall back to JPEG path.
            if (frame.image.size < w * h) {
                Log.w("FotoapparatCamera", "Unexpected NV21 size ${frame.image.size} (expected >= ${w*h}); falling back to JPEG path")
                return getImageJpeg(frame)
            }
            val y = frame.image
            val (outW, outH) = when (frame.rotation) {
                90, 270 -> h to w
                else -> w to h
            }
            val pixels = IntArray(outW * outH)
            val black = Color.BLACK
            val white = Color.WHITE
            for (j in 0 until outH) {
                for (i in 0 until outW) {
                    val sx: Int; val sy: Int
                    when (frame.rotation) {
                        90  -> { sx = j;          sy = w - 1 - i }
                        180 -> { sx = w - 1 - i;  sy = h - 1 - j }
                        270 -> { sx = h - 1 - j;  sy = i }
                        else -> { sx = i;         sy = j }
                    }
                    val luma = y[sy * w + sx].toInt() and 0xFF
                    pixels[j * outW + i] = if (luma < threshold) black else white
                }
            }
            val bmp = Bitmap.createBitmap(outW, outH, Bitmap.Config.ARGB_8888)
            bmp.setPixels(pixels, 0, outW, 0, 0, outW, outH)
            return bmp
        }
        ```
      - Rename the existing `getImage(frame)` (lines 195-202) to `private fun getImageJpeg(frame: Frame): Bitmap` and KEEP it as the fallback. This is what the defensive guard above falls back to.
      - Update `processFrame` (modified in Task 3) to use the new direct path:
        ```kotlin
        // OLD: val bitmap = getImage(frame)
        // NEW:
        val bitmap = nv21ToBinaryBitmap(frame)  // already grayscale + binarized + rotated
        val cropped = calculateCutoutRectCardSize(bitmap, true)
        val processedBitmap = cropped  // preprocessImage is now a no-op since nv21ToBinaryBitmap already thresholded
        ```
        The old `preprocessImage(cropped)` call becomes redundant since `nv21ToBinaryBitmap` already produced a binarized bitmap. Remove the `preprocessImage(cropped)` line in `processFrame` and just pass `cropped` directly. Also recycle `bitmap` after creating `cropped` (since `Bitmap.createBitmap(bitmap, ...)` may copy depending on dimensions — call `if (cropped !== bitmap) bitmap.recycle()`).
      - **Verification step (per RESEARCH.md Pitfall P5 line 448 + line 232):** rotation direction must match the existing `rotateBitmap(image, -frame.rotation)` semantics. The mapping above (90 → `sx=j, sy=w-1-i`) is the standard 90° CW rotation; verify visually on first device run that an upright passport frame OCRs correctly, NOT sideways. If it OCRs sideways, swap the 90 and 270 cases.
      - Leave `preprocessImage(bitmap)` (line 211) in place — it still delegates to `MrzOcr.preprocess`, which the static path uses. Live path no longer calls it.

    Atomic commit message:
      `perf(02-05): direct NV21 Y-plane → thresholded ARGB_8888 bitmap on Android live path`
  </action>
  <verify>
    <automated>cd example && cd android && ./gradlew :app:assembleDebug</automated>
  </verify>
  <done>
    `grep -n "compressToJpeg\\|YuvImage" android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FotoapparatCamera.kt` returns ONLY the fallback `getImageJpeg` (one site). `processFrame` calls `nv21ToBinaryBitmap`. Manual verification on a device (Task 8) confirms live OCR still parses correctly. Parallelizable: NO (touches the same file as Tasks 2 + 3).
  </done>
</task>

<!-- ============================================================
     TASK 6 — iOS quick wins: shared CIContext + takePhoto resize/EXIF early-return
     ============================================================ -->
<task type="auto" tdd="false">
  <name>Task 6: iOS shared CIContext + takePhoto skip resize/EXIF when no-op</name>
  <files>
    ios/Classes/MrzImageOcr.swift (modify),
    ios/Classes/MRZScannerView.swift (modify),
    ios/Classes/CGImage+Orientation.swift (modify)
  </files>
  <behavior>
    - All `MrzImageOcr.preprocess` calls share a single `CIContext` instance instead of allocating one per call (RESEARCH.md lines 275-294).
    - `MRZScannerView.resize(_:)` returns the input unchanged when image dimensions are already within 720×1280 (RESEARCH.md lines 311-323).
    - `createMatchingBackingDataWithImage(imageRef:orientation:)` returns the input unchanged when `orientation == .up` (RESEARCH.md lines 325-333).
    - Live OCR output unchanged. Photo output unchanged for the (common) already-correctly-sized + already-upright cases.
    - Verify-only confirmation that `MrzImageOcr.shared.tesseract` is `lazy` (it is — `MrzImageOcr.swift:15-21`); add an assertion comment so future maintainers don't accidentally rebuild it per call.
  </behavior>
  <action>
    `MrzImageOcr.swift`:
      - Add static, near top of class (line ~13):
        ```swift
        // Shared across live + static paths. CIContext is documented thread-safe.
        // Replaces per-call CIContext(options: nil) (was at line 87).
        static let sharedCIContext = CIContext(options: nil)
        ```
      - Replace the `let context = CIContext(options: nil)` line (currently `MrzImageOcr.swift:87`) with `let context = Self.sharedCIContext`.
      - Above the `lazy var tesseract: SwiftyTesseract` (line 15), add a `// LOCKED:` comment:
        ```swift
        // LOCKED — DO NOT change to a non-lazy initializer or rebuild per call.
        // The whole point of the shared singleton is one-time init for the
        // lifetime of the app. Live + static paths both share this instance;
        // serialization is enforced upstream (live: serial frame queue;
        // static: SwiftFlutterMrzScannerPlugin global queue + the one-call-at-
        // a-time semantics of FlutterMethodChannel handlers per channel).
        ```

    `MRZScannerView.swift`:
      - Modify `resize(_:)` (lines 386-414) — early return:
        ```swift
        func resize(_ image: CGImage) -> CGImage? {
            let imageWidth = Float(image.width)
            let imageHeight = Float(image.height)
            let maxWidth: Float = 720.0
            let maxHeight: Float = 1280.0
            // Skip resize when already within target bounds (no-op draw avoided).
            if imageWidth <= maxWidth && imageHeight <= maxHeight {
                return image
            }
            // ... existing logic from line 387 onward
        }
        ```

    `CGImage+Orientation.swift`:
      - Modify `createMatchingBackingDataWithImage(imageRef:orientation:)` — add early return at function entry:
        ```swift
        func createMatchingBackingDataWithImage(imageRef: CGImage?, orientation: UIImage.Orientation) -> CGImage? {
            guard let imageRef = imageRef else { return nil }
            if orientation == .up {
                return imageRef  // no rotation needed; skip CGContext allocation + draw
            }
            // ... existing logic
        }
        ```
        Note: returning the original `CGImage` reference for `.up` is safe because `CGImage` is immutable. Verify no caller mutates the result (a search for `applyExifOrientation`/`createMatchingBackingDataWithImage` callers should show only read-after-create usage).

    Atomic commit message:
      `perf(02-06): iOS shared CIContext; takePhoto skip resize/EXIF when no-op`
  </action>
  <verify>
    <automated>cd example/ios && pod install && xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Debug -sdk iphonesimulator -quiet build CODE_SIGNING_ALLOWED=NO</automated>
  </verify>
  <done>
    `grep -n "CIContext(options:" ios/Classes/MrzImageOcr.swift` returns exactly ONE line (the static let). `grep -n "if orientation == .up" ios/Classes/CGImage+Orientation.swift` shows the early return. `grep -n "imageWidth <= maxWidth" ios/Classes/MRZScannerView.swift` shows the resize early return. iOS example builds. Parallelizable with Task 4 only after Task 4 lands first (both touch `MRZScannerView.swift`); recommend running Task 4 → Task 6 sequentially.
  </done>
</task>

<!-- ============================================================
     TASK 7 — Verify-only no-ops: iOS lazy tesseract + Android live-path EXIF skip
     ============================================================ -->
<task type="auto" tdd="false">
  <name>Task 7: Confirm pre-existing wins (iOS SwiftyTesseract lazy; Android live EXIF skip) — comments only</name>
  <files>
    android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FotoapparatCamera.kt (modify, comments only),
    ios/Classes/MrzImageOcr.swift (modify, comments only — overlaps Task 6's "LOCKED" comment; merge if Task 6 already added it)
  </files>
  <behavior>
    - No code changes. Two assertions documented as comments so future maintainers don't break invariants the audit confirmed are already correct.
    - Per RESEARCH.md lines 296-302: Android live-path goes through `MrzOcr.runTesseract` (now `runTesseractWith` after Task 2), NOT `MrzOcr.scanImage` — therefore `applyExif` is NEVER invoked on live frames. This is correct and intentional.
    - Per RESEARCH.md lines 100-106: iOS `MrzImageOcr.shared.tesseract` is already `lazy var`; init runs once.
  </behavior>
  <action>
    `FotoapparatCamera.kt`:
      - Above the `scanMRZ(bitmap)` function (modified in Task 2), add:
        ```kotlin
        // LIVE-PATH EXIF NOTE:
        // Live frames are routed through MrzOcr.runTesseractWith, NOT
        // MrzOcr.scanImage. Therefore MrzOcr.applyExif() is NEVER called on
        // live frames — `frame.rotation` (handled in nv21ToBinaryBitmap) is the
        // only orientation source the live path needs. Static-path scanImage
        // continues to apply EXIF for image_picker / takePhoto inputs.
        // Do not "factor out" by routing live frames through scanImage(bytes).
        ```
    `MrzImageOcr.swift`:
      - If Task 6 already added the `// LOCKED — DO NOT change to a non-lazy initializer ...` comment above `lazy var tesseract`, this task is a no-op. Otherwise, add it now (verbatim from Task 6 action).

    Atomic commit message:
      `docs(02-07): document already-correct invariants (Android live EXIF skip; iOS lazy tesseract)`
  </action>
  <verify>
    <automated>cd example && flutter test ../test/static_channel_test.dart && cd android && ./gradlew :app:assembleDebug</automated>
  </verify>
  <done>
    `grep -n "LIVE-PATH EXIF NOTE" android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FotoapparatCamera.kt` returns one match. `grep -n "LOCKED" ios/Classes/MrzImageOcr.swift` returns one match. No production-code semantics changed. Phase 1 unit test 3/3.
  </done>
</task>

<!-- ============================================================
     TASK 8 — Re-run benchmark; record after-numbers; manual live verification
     ============================================================ -->
<task type="checkpoint:human-verify" gate="blocking">
  <what-built>
    - Tasks 1-7 landed: benchmark scaffolding + baseline, Android Tesseract cache + dispose-leak fix + concurrency lock, Android frame throttle, iOS frame throttle + reused VNRequest, Android NV21 direct path, iOS shared CIContext + takePhoto early-returns, comment-only invariants.
    - Phase 1 contract preserved: `mrzscanner_static` channel name, method, args shape, and `test/static_channel_test.dart` all unchanged.
  </what-built>
  <how-to-verify>
    A. Re-run the benchmark and capture after-numbers:
       1. `cd example && flutter test integration_test/scan_image_bench_test.dart --reporter=expanded` on the SAME device used for the baseline.
       2. Read the JSON line from stdout. Compare against `02-BASELINE.md`:
          - `gap_cold_minus_p50_ms` should DROP substantially (this is the per-call Tesseract `init()` cost we eliminated).
          - `warm_p50_ms` should be LOWER than baseline `warm_p50_ms`.
          - `cold_ms` may be roughly unchanged (cold pays init regardless).
       3. Append the after-numbers to the phase SUMMARY (`02-01-SUMMARY.md`) with a side-by-side table.
       4. PASS criteria: warm p50 lower than baseline by a clear margin (any meaningful drop is acceptance; a single-millisecond fluctuation is not). FAIL criteria: warm p50 higher than baseline OR `gap_cold_minus_p50_ms` not reduced.

    B. Manually verify the live camera path on a real device (Android AND iOS if possible — at minimum one):
       1. `cd example && flutter run` on a physical device. Tap "Live camera scan".
       2. Hold a passport's MRZ band steadily in frame. Confirm `onParsed` fires and a parsed result is shown — same behavior as Phase 1.
       3. Move the camera around aggressively for 30 seconds. Confirm:
          - Preview stays smooth (no growing latency).
          - The app does NOT OOM or crash.
          - When you re-stabilize on the MRZ, parse fires within ~1 sec.
       4. Test flashlight on/off, `takePhoto` (cropped + uncropped). Confirm same behavior as Phase 1.
       5. Repeat tear-down test: navigate away from the camera page and back 5 times. Confirm:
          - On Android, no `TessBaseAPI` leak warnings in `adb logcat` (the cached API is recycled per dispose).
          - On iOS, no obvious memory growth in Xcode's memory gauge across the cycles.

    C. Phase 1 contract regression check:
       6. `flutter test test/static_channel_test.dart` — must still pass 3/3.
       7. `flutter analyze` from plugin root — no new warnings introduced.

    If both A and B pass on at least one platform, type "approved". Note in the SUMMARY which platform was bench-tested and which was manually verified. If A fails (no win) OR B fails (regression), describe the failure and we revise.
  </how-to-verify>
  <resume-signal>Type "approved" once benchmark shows a clear win AND live-path manual verification passes on at least one platform. Otherwise describe the failure mode.</resume-signal>
</task>

</tasks>

<verification>
  <phase_level>
    Static path:
      - `flutter test test/static_channel_test.dart` — 3/3 green (Phase 1 contract intact).
      - `flutter test integration_test/scan_image_bench_test.dart` — runs end-to-end. After-numbers show `warm_p50_ms` lower than baseline, `gap_cold_minus_p50_ms` reduced. Numbers recorded in `02-01-SUMMARY.md`.
      - `grep -rn "mrzscanner_static" lib android ios test` — channel name unchanged across both platforms.
      - `grep -rn "TessBaseAPI()" android/src/main/kotlin/` — exactly TWO direct construction sites (live + static cache).
      - `grep -rn "compressToJpeg\\|YuvImage" android/src/main/kotlin/` — appears ONLY in the fallback `getImageJpeg`.

    Live path (manual on device, Task 8):
      - Visibly smoother preview under sustained scanning vs. pre-phase build (no pile-up).
      - `onParsed` callback still fires correctly with valid MRZ documents.
      - 5x camera open/close cycles do not cause memory growth or `TessBaseAPI` leaks (Android `adb logcat`, iOS Xcode memory gauge).
      - Flashlight + takePhoto unchanged.

    Build hygiene:
      - `cd example/android && ./gradlew :app:assembleDebug` — green.
      - `cd example/ios && pod install && xcodebuild ... build CODE_SIGNING_ALLOWED=NO` — green.
      - `flutter analyze` — no new warnings.
  </phase_level>
</verification>

<success_criteria>
  1. Tesseract is initialized at most ONCE per scanning session on Android (live path) and ONCE process-wide for the static path (PERF-01). iOS confirmed-unchanged (already lazy). Cached Android `TessBaseAPI` is recycled in `dispose()` — no leak.
  2. Live frame loop drops frames while OCR is in flight on both platforms (PERF-02). Verified by code review (`AtomicBoolean` + `DispatchSemaphore` gates) AND manual sustained-scan test.
  3. Android live path no longer round-trips YUV→JPEG→Bitmap; conversion is direct via `nv21ToBinaryBitmap`. iOS reuses one `VNDetectTextRectanglesRequest` and one shared `CIContext` across all calls (PERF-03).
  4. Benchmark shows a clear cold-vs-warm gap drop on Android (Tesseract init no longer per call), and warm p50 lower than baseline.
  5. No regression in MRZ accuracy or in the static `scanImage` API: `test/static_channel_test.dart` 3/3, manual live-path test parses MRZ correctly.
</success_criteria>

<output>
After completion, create `.planning/phases/02-scan-throughput/02-01-SUMMARY.md` per
$HOME/.claude/get-shit-done/templates/summary.md. Capture:
  - Side-by-side baseline vs. after numbers (cold, p50, p99, mean, gap) — pull from `02-BASELINE.md` and the post-Task-8 bench run.
  - Which device + OS the bench ran on (both runs MUST be the same device; note if not).
  - Live-path manual verification result (which platform, document used, sustained-scan observation).
  - Tear-down/leak check result (5x camera open/close, no leak observed).
  - Any deviations from this plan and why (e.g., synthetic MRZ didn't OCR → swapped to user-supplied sample).
  - Confirmation that the deprecated `MrzOcr.runTesseract(context, bitmap)` is either removed or has zero callers.
</output>

## PLAN CREATED
