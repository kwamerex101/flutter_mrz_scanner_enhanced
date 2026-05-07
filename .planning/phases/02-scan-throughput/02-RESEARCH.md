# Phase 2: Scan throughput - Research

**Researched:** 2026-05-07
**Domain:** Native (Android Kotlin / iOS Swift) image processing + OCR perf
**Confidence:** HIGH (decisions are locked; research confirms feasibility + line refs)

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Tesseract caching strategy** — Cache one `TessBaseAPI` per scanning session.
- Live path: `FotoapparatCamera` owns a single `TessBaseAPI` initialized when camera starts, recycled on stop. Frame OCR reuses via `setImage` + `utF8Text`.
- Static path: `MrzOcr` keeps a lazily-initialized, synchronized cached instance keyed by traineddata path. First `scanImage` triggers init; subsequent calls reuse. Lives for app lifetime.
- iOS: `MrzImageOcr.shared` already keeps `SwiftyTesseract` as stored property — confirm reuse and remove any unintended re-init paths.

**Frame throttling** — Drop-while-busy on both platforms.
- Android: `AtomicBoolean ocrInFlight` in `FotoapparatCamera`. `processFrame` early-returns if true; sets true on `scope.launch`, sets false in `finally`.
- iOS: `DispatchSemaphore(value: 1)` in `MRZScannerView`. `captureOutput` does `tryWait`; skips if busy.

**Android YUV pipeline** — Pure-Kotlin / Android-native NV21 → grayscale conversion. Read directly from Y plane, threshold in-place, write to a single ARGB_8888 Bitmap. Skip JPEG entirely. Refactor `getImage` + `preprocessImage` into a single `nv21ToBinaryBitmap(frame, rotation)` helper. Static path keeps existing `BitmapFactory.decodeByteArray + applyExif + preprocess` flow.

**Quick wins (all four)**
1. iOS `VNDetectTextRectanglesRequest` reuse — store as property of `MRZScannerView`.
2. iOS `CIContext` cache — `MrzImageOcr` keeps a lazy-static shared `CIContext`.
3. Android EXIF skip in live path — `frame.rotation` already applied; do not call `readExifOrientation` on the live path through `MrzOcr`.
4. iOS `takePhoto` conditional resize — skip 720×1280 resize when already smaller; skip EXIF when `Orientation == .up`.

**Benchmark harness** — Full benchmark for static path (Dart). `test/perf/scan_image_bench.dart` (or `benchmark/`) runs `MRZScanner.scanImage(bytes)` on a fixed bundled MRZ sample, N iterations, reports min/p50/p99/mean. Runs against device/emulator.

### Claude's Discretion
- Exact internal module layout for the Tesseract cache helper (e.g., `MrzOcr.acquireBaseApi(context)` vs nested object) — pick the simplest correct shape.
- Number of benchmark iterations and exact JSON format.
- Whether benchmark sample is synthetic or user-supplied.
- Whether to use `synchronized` block, single-thread `Executor`, or `ThreadLocal` for the static-path cache concurrency.

### Deferred Ideas (OUT OF SCOPE)
- Adaptive throttling targeting specific FPS — only if drop-while-busy is too aggressive in practice.
- libyuv / NEON — only if pure-Kotlin YUV→grayscale becomes the next bottleneck.
- RenderScript — deprecated; only emergency fallback.
- Vision-based MRZ band detection on Android — separate phase.
- ML Kit / non-Tesseract engine swap.
- Continuous benchmark in CI.
- Web platform.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| PERF-01 | Tesseract initialized at most once per scanning session; properly released on teardown. | Tesseract caching plan (Android live + static, iOS) — sections 1, 2, 3 below. |
| PERF-02 | Live frame loop drops frames while OCR in flight on both platforms. | Frame throttling plan — sections 4, 5 below. |
| PERF-03 | Android live path no longer round-trips YUV→JPEG→Bitmap; iOS reuses `VNDetectTextRectanglesRequest` and `CIContext`. | Android YUV plan (section 6, 7) + iOS quick wins (8, 9). |
</phase_requirements>

## Summary

Phase 2 is a pure refactor with no API surface change — the channel contract from Phase 1 (`mrzscanner_static` / `scanImage`) is preserved verbatim and `test/static_channel_test.dart` keeps passing.

Three high-impact wins land on Android: a cached `TessBaseAPI` (eliminates ~hundreds of ms of `init()` per frame), a `drop-while-busy` flag on the frame processor (caps memory), and a direct NV21 Y-plane → thresholded `ARGB_8888` Bitmap conversion (eliminates JPEG encode + decode + extra bitmap allocations per frame). On iOS the wins are smaller but real: a hoisted `CIContext`, a reused `VNDetectTextRectanglesRequest`, a `DispatchSemaphore`, and conditional resize/EXIF in `takePhoto`. A Dart-side benchmark harness in `benchmark/scan_image_bench.dart` (or `integration_test/`) provides numeric proof.

**Primary recommendation:** Implement in this dependency order: (1) Tesseract cache (Android + iOS) → (2) benchmark harness with cold/warm baseline → (3) frame throttling → (4) NV21 direct path → (5) iOS quick wins. The benchmark must capture **baseline numbers before any optimization lands**, otherwise the wins are unprovable.

## Tesseract caching plan (Android + iOS)

### Android — live path (`FotoapparatCamera`)

**Current state** [VERIFIED: source]:
- `MrzOcr.runTesseract` (`MrzOcr.kt:101-117`) instantiates a fresh `TessBaseAPI`, calls `init()`, `setVariable()`, sets `pageSegMode`, `setImage()`, reads `utF8Text`, then `recycle()` — every call.
- `FotoapparatCamera.scanMRZ` (`FotoapparatCamera.kt:216-218`) calls `MrzOcr.runTesseract(context, bitmap)` per frame.
- `init()` reloads `ocrb.traineddata` from `cacheDir/tessdata/` on every call. The trained-data extraction itself is gated by `MrzOcr.ensureTrainedData` (already cached via `@Volatile trainedDataReady`), but the Tesseract `init()` still re-reads the file on disk.

**API confirmation** [CITED: tesseract4android `cz.adaptech:tesseract4android:4.1.1` is a JNI binding around the Tesseract 4.x C++ API; `TessBaseAPI` mirrors `tesseract::TessBaseAPI`]:
- `TessBaseAPI.setImage(Bitmap)` followed by `getUTF8Text()` (Kotlin property `utF8Text`) is the supported reuse pattern. Tesseract 4.x explicitly supports calling `SetImage` repeatedly on the same instance after `Init`. [ASSUMED — based on Tesseract C++ docs; verify against tesseract4android javadoc on first task]
- `setImage(Bitmap)` triggers a JNI call that copies pixel data into Tesseract's internal Pix structure; the Java-side `Bitmap` is **not retained** beyond the call — caller is free to recycle the Bitmap immediately after `getUTF8Text()` returns. [ASSUMED — verify]
- There is no public `clear()`. Calling `setImage` again replaces the prior image; the previous Pix is freed by the new `setImage`. [ASSUMED]
- `recycle()` (or `end()` on older bindings) releases the native Pix + tessdata handles. After `recycle()` the instance is unusable.

**Plan (live path):**
- Add `private var tessApi: TessBaseAPI? = null` and `private val tessLock = Any()` as fields on `FotoapparatCamera` (insert near line 31-34, alongside `mainExecutor` / `job` / `scope`).
- Add `private fun ensureTessApi(): TessBaseAPI` that double-checked-locks: if null, create `TessBaseAPI()`, call `init(context.cacheDir.absolutePath, "ocrb")`, set whitelist, set `pageSegMode`. Return cached.
- Refactor `scanMRZ` (`FotoapparatCamera.kt:216-218`) to call `MrzOcr.runTesseractWith(api, bitmap)` (new overload) where the API instance is passed in.
- Add `fun stop()` / extend `dispose()` (currently at `FotoapparatCamera.kt:321-323`) to call `synchronized(tessLock) { tessApi?.recycle(); tessApi = null }`.
- Tie lifecycle to camera start/stop: `MRZScannerView.dispose()` (`FlutterMrzScannerPlugin.kt:93-95`) already calls `cameraView.fotoapparat.stop()`. Extend it to also call `cameraView.dispose()` so the cached `TessBaseAPI` is recycled. **Currently `MRZScannerView.dispose()` does NOT call `cameraView.dispose()` — that's a pre-existing leak of the coroutine job.** Fix as part of this phase.

### Android — static path (`MrzOcr`)

**Plan (static path):**
- Add inside `MrzOcr` (object): `@Volatile private var sharedBaseApi: TessBaseAPI? = null` + `private val baseApiLock = Any()`.
- Add `internal fun acquireSharedBaseApi(context: Context): TessBaseAPI` with double-checked locking: ensures trained data, lazily inits on first call. App-lifetime — never recycled.
- Refactor `runTesseract(context, bitmap)` (`MrzOcr.kt:101-117`) to delegate: get the shared API, `synchronized(baseApiLock) { api.setImage(bitmap); api.utF8Text }`.
- Keep the existing function signature so `FotoapparatCamera` (currently calls `MrzOcr.runTesseract(context, bitmap)`) still compiles, but switch its callsite to `runTesseractWith(api, bitmap)` to use the live-path-owned instance.
- The `synchronized` block protects the static path from the `Thread { ... }.start()` per-call concurrency in `FlutterMrzScannerPlugin.handleScanImage` (`FlutterMrzScannerPlugin.kt:60-69`). See **Concurrency** section below.

**Confirmation: only `FotoapparatCamera` and `MrzOcr.scanImage` call `runTesseract`** [VERIFIED: grep on the codebase — `MrzOcr.runTesseract` is referenced from `MrzOcr.scanImage` (line 63) and `FotoapparatCamera.scanMRZ` (line 217); nowhere else].

### iOS — `MrzImageOcr.shared`

**Current state** [VERIFIED: source]:
- `MrzImageOcr.shared` is a singleton (`MrzImageOcr.swift:13`).
- `tesseract` is a `lazy var` stored property (`MrzImageOcr.swift:15-21`) — initialized **once on first access** for the lifetime of the singleton. Confirmed: NOT re-created per `performOcr` call.
- Live path `MRZScannerView.mrz(from:)` (`MRZScannerView.swift:109-111`) calls `MrzImageOcr.shared.performOcr(on:)` — same singleton.
- Static path `SwiftFlutterMrzScannerPlugin.swift:24` calls `MrzImageOcr.shared.scanImage(data:)` which calls `performOcr(on:)` — same singleton.

**Conclusion (iOS Tesseract):** No code change needed for caching — already cached. Phase 2 task is a verification-only "confirm and document" task with a comment in the source.

**Caveat:** SwiftyTesseract holds a single internal `TessBaseAPI`; concurrent calls from different threads are not safe. The static-path `DispatchQueue.global(qos: .userInitiated).async` (line 22) and the live-path serial frame queue (line 201) **can collide** if a user invokes `MRZScanner.scanImage(...)` while the camera is also running. Add a serial dispatch queue inside `MrzImageOcr` to serialize `performOcr` calls. See **Concurrency** section.

## Frame throttling plan (Android + iOS)

### Android (`FotoapparatCamera.processFrame`)

**Current state** [VERIFIED: source, `FotoapparatCamera.kt:175-193`]:
- `processFrame(frame)` does the YUV→JPEG→Bitmap conversion, crop, preprocess **synchronously on the Fotoapparat frame thread**, then dispatches OCR via `scope.launch { scanMRZ(...) }` on `Dispatchers.IO`.
- No in-flight check. Coroutines accumulate; backlog grows under load.

**Plan:**
- Add field at line ~33 (alongside `job`/`scope`):
  ```kotlin
  private val ocrInFlight = java.util.concurrent.atomic.AtomicBoolean(false)
  ```
- In `processFrame` (line 176), after computing `processedBitmap` (line 181), gate the launch:
  ```kotlin
  if (!ocrInFlight.compareAndSet(false, true)) {
      processedBitmap.recycle()  // drop the frame's bitmap
      return
  }
  scope.launch {
      try {
          val mrzText = scanMRZ(processedBitmap)
          val fixedMrz = extractMRZ(mrzText)
          withContext(Dispatchers.Main) {
              messenger.invokeMethod("onParsed", fixedMrz)
          }
      } finally {
          processedBitmap.recycle()
          ocrInFlight.set(false)
      }
  }
  ```
- **Important:** `compareAndSet` happens AFTER preprocessing in this layout; the preprocessing still runs every frame on the Fotoapparat thread. Better — move the gate **before** preprocessing (line 177) so we also skip the preprocessing cost when busy. Final shape: gate first, then `getImage`/preprocess/launch only if we won the gate.
  ```kotlin
  private fun processFrame(frame: Frame) {
      if (!ocrInFlight.compareAndSet(false, true)) return
      val bitmap = getImage(frame)
      val cropped = calculateCutoutRectCardSize(bitmap, true)
      val processedBitmap = preprocessImage(cropped)
      scope.launch { try { ... } finally { ocrInFlight.set(false); processedBitmap.recycle() } }
  }
  ```
  This is the recommended diff.

### iOS (`MRZScannerView.captureOutput`)

**Current state** [VERIFIED: source, `MRZScannerView.swift:287-326`]:
- Frame queue is `DispatchQueue(label: "video_frames_queue", qos: .userInteractive)` — **serial** (line 201). Calls to `captureOutput` are serial; concurrent invocation cannot happen.
- `videoOutput.alwaysDiscardsLateVideoFrames = true` (line 202) — capture pipeline drops late frames AT THE CAPTURE LAYER, but the OCR work itself still runs synchronously on the frame queue. While OCR is running, frames pile in the capture queue and are dropped by AVFoundation. So today the throttling is implicit; explicit throttling matters once we move OCR to a background queue (which we should — current code blocks the frame queue, killing preview FPS).

**Plan:**
- Add property near line 19 (alongside `isScanningPaused`):
  ```swift
  private let ocrSemaphore = DispatchSemaphore(value: 1)
  private let ocrQueue = DispatchQueue(label: "mrz_ocr_queue", qos: .userInitiated)
  ```
- Refactor `captureOutput` (line 287) to:
  ```swift
  guard ocrSemaphore.wait(timeout: .now()) == .success else { return }
  guard let pixelBuffer = ..., let cgImage = pixelBuffer.cgImage else {
      ocrSemaphore.signal(); return
  }
  let documentImage = self.documentImage(from: cgImage)
  ocrQueue.async { [weak self] in
      defer { self?.ocrSemaphore.signal() }
      // existing VNImageRequestHandler + VNDetectTextRectanglesRequest work
  }
  ```
- This unblocks the frame queue so preview stays smooth while OCR runs in parallel.

## Android YUV → grayscale Bitmap plan

### NV21 layout & rotation [CITED: Android `ImageFormat.NV21` documentation; Fotoapparat 2.x `Frame` class]

**Confirmed:**
- Fotoapparat delivers preview frames as NV21 by default. `Frame.image` is a `ByteArray` of length `width * height * 3 / 2`.
- NV21 layout: first `width * height` bytes = Y plane (full-resolution luminance, **already grayscale**). Remaining `width * height / 2` bytes = interleaved VU (subsampled 2x in both dimensions).
- `Frame.rotation` is the angle (0/90/180/270, in degrees) by which the buffer must be rotated to display upright. Matches the camera sensor orientation vs. device orientation.
- The current code (`FotoapparatCamera.kt:201`) calls `rotateBitmap(image, -frame.rotation)` — note the **negation**. Verify direction during implementation by visually confirming a known portrait frame OCRs correctly post-refactor.

**Stride / padding:**
- `Frame.image` from Fotoapparat 2.7 is a tightly-packed NV21 buffer with no row padding (`rowStride == width` for the Y plane). [ASSUMED — confirm against Fotoapparat 2.7 source on first implementation task; if wrong, add stride handling]

### Recommended path: direct Y-plane → thresholded ARGB_8888 Bitmap (single allocation, single pass)

```kotlin
/**
 * Convert NV21 frame's Y plane to a binarized ARGB_8888 Bitmap (BLACK/WHITE),
 * applying the same threshold as MrzOcr.preprocess and rotating to upright.
 * No JPEG roundtrip; no intermediate grayscale Bitmap.
 */
private fun nv21ToBinaryBitmap(frame: Frame, threshold: Int = 128): Bitmap {
    val w = frame.size.width
    val h = frame.size.height
    val y = frame.image  // first w*h bytes are the Y plane

    // Step 1: rotate Y indices into a target buffer of ints (ARGB BLACK/WHITE).
    val (outW, outH) = when (frame.rotation) {
        90, 270 -> h to w
        else -> w to h
    }
    val pixels = IntArray(outW * outH)
    val black = android.graphics.Color.BLACK
    val white = android.graphics.Color.WHITE
    for (j in 0 until outH) {
        for (i in 0 until outW) {
            val (sx, sy) = when (frame.rotation) {
                90 -> j to (w - 1 - i)        // 90° CW source mapping
                180 -> (w - 1 - i) to (h - 1 - j)
                270 -> (h - 1 - j) to i        // 90° CCW
                else -> i to j
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

**Confirm direction of `frame.rotation` vs the existing `rotateBitmap(image, -frame.rotation)` (line 201)** during implementation — the rotation table in the helper above must match what the existing code does, or live-frame OCR will be sideways. The simplest approach: log `frame.rotation` for known device orientations and confirm.

**Cropping:** `calculateCutoutRectCardSize` currently runs on the rotated full-frame bitmap (`FotoapparatCamera.kt:180`). After this refactor, two options:
1. Crop **first** in source (Y-plane) coordinates, then rotate the cropped region — fewer pixels touched.
2. Rotate full frame as above, then crop the resulting bitmap with `Bitmap.createBitmap(bmp, x, y, w, h)` — simpler, same correctness.

Recommendation: option (2) for the first cut. Option (1) is a future optimization if profiling shows the per-pixel loop is hot.

**Bitmap reuse across frames** — Tesseract `setImage(bitmap)` copies pixels into its internal Pix on each call, so you could keep one reusable `Bitmap` and `setPixels` into it each frame. **However**, the rotated dimensions and cropped dimensions can vary between frames (e.g., orientation change), and `Bitmap` size is immutable post-create. Skip the reuse optimization in this phase — `Bitmap.createBitmap` of an int-array-backed ARGB_8888 is cheap relative to the pixel loop and OCR. Defer until profiling proves it matters.

### Threshold value [VERIFIED: source]

- `MrzOcr.preprocess` (`MrzOcr.kt:81`): `val threshold = 128` — fixed 128 on the red channel of an already-grayscale (saturation 0) bitmap. Equivalent to thresholding luma at 128.
- The new direct path applies the same fixed threshold of 128 to the Y plane → recognition behavior is preserved bit-for-bit (modulo tiny rounding differences from `setSaturation(0)` vs raw Y channel — Y in NV21 is BT.601 luma, the `setSaturation(0)` ColorMatrix uses ITU-R BT.601 weights, so they're effectively the same up to ±1 luma per pixel).
- **No Otsu in current code.** Don't introduce Otsu in this phase — it's a behavior change the user didn't approve.
- Static path keeps the existing two-bitmap `MrzOcr.preprocess` flow because it doesn't have an NV21 buffer — it has decoded RGBA from `BitmapFactory`.

## iOS quick wins

### 1. `VNDetectTextRectanglesRequest` reuse [VERIFIED: source]

**Current state:** Allocated inside the closure in `captureOutput` (`MRZScannerView.swift:297`).

**Plan:** Cannot fully reuse a single instance because the completion handler captures `documentImage` (which changes every frame) for coordinate scaling (lines 306-307). Two approaches:

**Option A (recommended):** Create the request **without a completion handler**, perform synchronously, read `request.results` after `perform([request])` returns. Then store the request as a `private lazy var`:
```swift
private lazy var textDetectionRequest: VNDetectTextRectanglesRequest = {
    let r = VNDetectTextRectanglesRequest()
    r.reportCharacterBoxes = false
    return r
}()
```
In `captureOutput`:
```swift
try? imageRequestHandler.perform([self.textDetectionRequest])
guard let results = self.textDetectionRequest.results as? [VNTextObservation] else { return }
// existing transform/filter/crop using documentImage
```
`results` is reset on each `perform()` call — no manual clearing needed. [CITED: Apple Vision framework: `VNRequest.results` is replaced on each `perform()`.] Reusing the request avoids per-frame allocation of the underlying ML model wrapper.

**Option B:** Keep the closure but reuse the request — `request.results` is overwritten on each perform, so reuse is safe even with a stored completion handler. This is more invasive (requires capturing `documentImage` differently) — prefer Option A.

### 2. `CIContext` cache [VERIFIED: source]

**Current state:** `MrzImageOcr.swift:87` builds `CIContext(options: nil)` per `preprocess()` call. Confirmed.

**Plan:** Hoist to a static.
```swift
final class MrzImageOcr {
    static let sharedCIContext = CIContext(options: nil)
    // ... existing code
    func preprocess(_ image: UIImage) -> UIImage {
        // ...
        if let outputCGImage = Self.sharedCIContext.createCGImage(threshold, from: threshold.extent) {
            return UIImage(cgImage: outputCGImage)
        }
        return image
    }
}
```

**Thread safety:** `CIContext` is documented as thread-safe — concurrent calls from multiple threads are supported. [CITED: Apple Core Image docs: "CIContext is thread-safe and can be shared across threads."] Sharing one static instance across the live path and static path is correct.

### 3. Skip EXIF in live Android path [VERIFIED]

**Current state:** Live path goes through `MrzOcr.runTesseract(context, bitmap)` (`FotoapparatCamera.kt:217`), which **does NOT** apply EXIF — only the higher-level `MrzOcr.scanImage(context, bytes)` (`MrzOcr.kt:54-70`) calls `applyExif`. **So the live path already skips EXIF.** No code change needed here.

However, `FotoapparatCamera.normalizeCapturedBitmap` (`FotoapparatCamera.kt:102-115`) is called from `takePhoto` (still photo) and DOES read EXIF — that's correct behavior, leave it alone.

**Conclusion:** No live-path EXIF skip needed; the audit item was based on an assumption that turned out to be already-correct on inspection. **Document this finding and skip the task** to avoid invalidating Phase 1.

### 4. iOS `takePhoto` conditional resize and EXIF skip [VERIFIED: source]

**Current state:**
- Unconditional 720×1280 resize in `MRZScannerView.swift:386-414`. The ratio gate at line 400-402 (`if ratio > 1 { ratio = 1 }`) prevents upscaling but **still re-draws into a new context** with full per-pixel work even when the image is already smaller. The image is reconstructed via `CGContext(...).draw(...)` regardless.
- EXIF rotation in `createMatchingBackingDataWithImage` (`CGImage+Orientation.swift:7-73`) — called from `MRZScannerView.swift:349`. Always rotates, even when `orientation == .up` (which maps to `degreesToRotate = 0, swapWidthHeight = false, mirrored = false` and thus a no-op draw — but the CGContext is still allocated and `draw()` is still called, copying every pixel).

**Plan:**
- `MRZScannerView.swift:386` — add early return at the top of `resize`:
  ```swift
  func resize(_ image: CGImage) -> CGImage? {
      let imageWidth = Float(image.width)
      let imageHeight = Float(image.height)
      let maxWidth: Float = 720.0
      let maxHeight: Float = 1280.0
      // Skip resize if image is already within bounds.
      if imageWidth <= maxWidth && imageHeight <= maxHeight {
          return image
      }
      // ... existing logic
  }
  ```
- `CGImage+Orientation.swift:7` — add early return in `createMatchingBackingDataWithImage`:
  ```swift
  func createMatchingBackingDataWithImage(imageRef: CGImage?, orientation: UIImage.Orientation) -> CGImage? {
      if orientation == .up {
          return imageRef
      }
      // ... existing logic
  }
  ```
  Note: this changes behavior for `.upMirrored` callers (still rotated correctly). `.up` returns the original `CGImage` reference. Verify no caller mutates the result.

## Benchmark harness plan (location, sample, metrics)

### Location: `benchmark/scan_image_bench.dart` (recommended)

**Three options considered:**

| Option | Pros | Cons |
|--------|------|------|
| (a) `integration_test/` with `flutter test integration_test/` | Real device, full plugin path | Heavier setup; integration_test dependency |
| (b) `benchmark/scan_image_bench.dart` invoked via `flutter test benchmark/scan_image_bench.dart` | Same engine as integration_test; lighter; idiomatic | Requires real plugin (i.e., must run on a device or emulator — `flutter test` without a device only runs Dart unit tests) |
| (c) `test/` with channel mocks | No device needed | Doesn't exercise native code → useless for perf |

**Recommendation: option (b).** Convention in the Flutter ecosystem is that `benchmark/` holds perf scripts. To exercise the actual native pipeline, the entry point is structured as an integration test (uses `IntegrationTestWidgetsFlutterBinding`) and invoked with:
```
flutter test integration_test/scan_image_bench_test.dart
```
i.e., **place under `integration_test/` for actual device execution** (option a's mechanics with option b's spirit). Add `integration_test:` to `dev_dependencies` in `pubspec.yaml`.

Final layout:
```
integration_test/
├── scan_image_bench_test.dart      # the bench, runnable per-platform
└── fixtures/
    └── sample_mrz.png              # see "Sample image" below
```

### Sample image: synthetic, generated at first run

**Three options considered:**

| Option | Verdict |
|--------|---------|
| (a) Synthetic MRZ rendered into a Flutter canvas at test setup, saved as PNG | Clean, no licensing, reproducible |
| (b) Public-domain MRZ specimen | Hard to source with confidence; ICAO specimens have unclear licensing terms |
| (c) User-supplied (drop at `integration_test/fixtures/sample_mrz.png`) | Brittle; benchmark not runnable out of the box |

**Recommendation: (a) synthetic.** Use the canonical TD3 sample already in `test/static_channel_test.dart:42` (`P<UTOERIKSSON<<ANNA<MARIA...`), render with monospace ocrb-like font onto a 1280×800 canvas with high contrast, save as PNG. The bench then reads this PNG and feeds bytes to `MRZScanner.scanImage`.

If rendering a synthetic MRZ that Tesseract reliably recognizes proves brittle (Tesseract may not parse a TTF-rendered approximation of OCR-B), fall back to (c): require a sample at `integration_test/fixtures/sample_mrz.png` and document this in the bench file's header comment.

### Metrics to capture

- **Cold-start latency:** time of first `MRZScanner.scanImage` call (includes Tesseract `init` on first invocation).
- **Warm latencies:** times of calls 2..N (post-init).
- **Statistics:** min, p50, p99, mean, stddev across warm calls.
- **The cold/warm gap:** explicitly report `cold - p50_warm` — this gap is exactly the per-call Tesseract `init()` cost we're eliminating.
- **Iterations:** 50 warm iterations is the sweet spot. Below 30 the p99 is noisy; above 100 the test is slow.

### Output format

Both: human-readable console table (for CI logs) + JSON file at `build/bench/scan_image_bench.json` for machine consumption / diffing.

```
$ flutter test integration_test/scan_image_bench_test.dart
== scan_image_bench ==
cold:    842 ms
warm n=50: min=38  p50=44  p99=78  mean=46  stddev=7
gap (cold - p50_warm): 798 ms
JSON: build/bench/scan_image_bench.json
```

### Baseline-first ordering

**Critical:** The benchmark task must be implemented and run **before** the Tesseract caching task lands, so we have baseline numbers. The plan should look like:
1. Task: build benchmark harness (no perf code changes yet) — record baseline cold/warm.
2. Tasks: Tesseract cache, throttling, NV21 — record after-numbers in PHASE-SUMMARY.md.
3. Verify success criteria from ROADMAP.md against the deltas.

## Concurrency / thread-safety

### Android — static path concurrency hazard

`FlutterMrzScannerPlugin.handleScanImage` (`FlutterMrzScannerPlugin.kt:60-69`) spawns a fresh `Thread { ... }.start()` per call. If a caller fires two `MRZScanner.scanImage(bytes)` calls in quick succession — or if a scanner widget is mounted (live path running) while a static `scanImage` is invoked — multiple threads will hit `MrzOcr.runTesseract` concurrently. With caching, that means concurrent `setImage` / `utF8Text` on the same `TessBaseAPI` — **not safe**.

**Three mitigations:**

| Option | Verdict |
|--------|---------|
| (a) `synchronized(MrzOcr.baseApiLock) { setImage; utF8Text }` block | Simple, correct, blocks-during-OCR. Acceptable since OCR is the dominant cost anyway. **Recommended.** |
| (b) Single-thread executor in plugin | Replaces `Thread { ... }.start()` with `executor.submit { ... }`; serializes naturally. Cleaner long-term but a bigger refactor. **Defer to a later phase.** |
| (c) `ThreadLocal<TessBaseAPI>` | Defeats the purpose — each thread re-`init()`s. Bad. |

**Plan:** Option (a). Wrap the cached-API `setImage`/`utF8Text` block in `synchronized(baseApiLock) { ... }`. Live path also takes the lock (shares the same lock object) so the live-path-owned API and the static-path-shared API don't interfere. Actually — they're **separate instances** (live owns its own, static shares its own), so two locks: one per instance. The live-path lock guards `FotoapparatCamera.tessApi`; the static-path lock guards `MrzOcr.sharedBaseApi`. They never share an instance.

**Wait**: are the live `FotoapparatCamera` API and the static `MrzOcr` API really separate? Per the locked decision (CONTEXT.md `### Tesseract caching strategy`), yes: live owns its own (recycled on stop), static keeps a singleton (app-lifetime). Document this clearly in code comments — it's the most likely thing for a future maintainer to "simplify" incorrectly.

### iOS — `SwiftyTesseract` concurrency

`SwiftyTesseract` wraps a single `TessBaseAPI`; concurrent calls from different threads are **not safe**. [ASSUMED — verify against SwiftyTesseract README]

The static path runs `MrzImageOcr.shared.scanImage(data:)` on `DispatchQueue.global(qos: .userInitiated)` (`SwiftFlutterMrzScannerPlugin.swift:22`). The live path runs OCR via `MRZScannerView.captureOutput` on the serial frame queue (now post-refactor: on `ocrQueue`). If both paths run simultaneously, they hit `MrzImageOcr.shared.tesseract` concurrently.

**Plan:** Add a serial dispatch queue inside `MrzImageOcr`:
```swift
private let ocrSerialQueue = DispatchQueue(label: "mrz_ocr_serial", qos: .userInitiated)
// then in performOcr:
return ocrSerialQueue.sync { tesseract.performOCR(on: preprocessedImage, completionHandler:) ... }
```
Or use an `NSLock` / `os_unfair_lock` around the `tesseract.performOCR` call. Lock approach is lower overhead. Either is fine.

### Vision request thread-safety

`VNImageRequestHandler.perform([request])` is synchronous; multiple handlers can run concurrently as long as each holds its own request, but a SINGLE `VNRequest` instance shared across concurrent `perform` calls is **not safe** because `request.results` is mutated by `perform`. The reused `textDetectionRequest` is safe ONLY because the iOS frame queue is serial AND the new `ocrQueue` is also serial. Document this constraint with a comment.

## Pitfalls & mitigations

| # | Pitfall | Mitigation |
|---|---------|------------|
| P1 | `TessBaseAPI` cached and concurrent access from live + static paths | Live and static use **separate instances**; each has its own lock. Documented in code comments. |
| P2 | `setImage(bitmap)` retaining bitmap and leaking | Tesseract copies pixel data; bitmap can be recycled after `utF8Text`. **Always `recycle()` the per-frame bitmap in a `finally`** to avoid native heap pressure regardless. |
| P3 | Dropping frames also drops the most-recent good frame if user holds card briefly | Acceptable for v1; CONTEXT.md explicitly chose drop-while-busy. Adaptive throttling deferred. |
| P4 | NV21 stride/padding assumption breaks on some devices | If `frame.image.size != width*height*3/2`, fall back to JPEG path. Add a runtime guard: `require(frame.image.size >= width*height) { "unexpected NV21 buffer" }` and log. |
| P5 | Rotation direction mismatch (90 vs 270, CW vs CCW) | The existing code uses `rotateBitmap(image, -frame.rotation)` — negative. Replicate exact mapping in `nv21ToBinaryBitmap`; verify visually with a test image on both portrait and landscape devices. |
| P6 | `MRZScannerView.dispose()` doesn't call `cameraView.dispose()` (`FlutterMrzScannerPlugin.kt:93-95`) — pre-existing leak that becomes more visible once we cache `TessBaseAPI` | Fix as part of this phase: add `cameraView.dispose()` to `MRZScannerView.dispose()`. The new `dispose()` recycles the cached `TessBaseAPI`. |
| P7 | iOS `VNDetectTextRectanglesRequest` reuse breaks if user holds an `MRZScannerView` and a static call runs simultaneously | The reused request lives on `MRZScannerView` and is only used from its serial frame queue. Static path uses its own request inside `MrzImageOcr.detectMrzRegion`. Two instances, no sharing. Document this. |
| P8 | iOS `CIContext` shared across paths — Core Image GPU context contention | Apple guarantees thread safety; perf impact of sharing < perf impact of per-call allocation. |
| P9 | Tesseract `init()` can fail silently if traineddata is corrupt | Wrap `init` in try/catch; on failure clear the cache file and re-extract from assets. (Existing `ensureTrainedData` doesn't validate; consider adding a length/SHA check in a follow-up phase — out of scope here.) |
| P10 | Synthetic MRZ may not OCR cleanly | Bench fallback: require user-supplied PNG; document in header comment. |
| P11 | `frame.size` vs `frame.image.size` mismatch (rare; some Fotoapparat versions) | Guard with `require`. |
| P12 | Phase 1 unit test (`test/static_channel_test.dart`) breaking from refactor | The test mocks the channel — refactors that change the channel name/method/args break it. **Touch nothing in `lib/src/mrz_scanner.dart` channel surface or `FlutterMrzScannerPlugin.handleScanImage`/`MrzStaticChannel.register` channel name/method.** |

## Open questions for the planner

1. **Synthetic MRZ vs user-supplied sample for bench** — recommend trying synthetic first; if Tesseract recognition is unreliable on the synthetic image, fall back to user-supplied. The planner should make this a single task with a fallback branch documented in its acceptance criteria, not two tasks.

2. **iOS Vision request reuse via Option A (no completion handler) vs Option B (closure)** — Option A is cleaner; planner should commit to it but accept that the diff to `MRZScannerView.captureOutput` is more invasive than the others (closure-to-imperative refactor). Allocate a separate task for this with its own line-by-line acceptance.

3. **Whether to extend `MRZScannerView.dispose()` (Android plugin) to call `cameraView.dispose()`** — this is a pre-existing leak unrelated to Phase 2 strictly, but caching `TessBaseAPI` makes it bite (every camera close/reopen leaks a `TessBaseAPI`). Recommend including it as a sub-task of the live-path Tesseract cache task.

4. **Ordering: benchmark first, or after fixes** — recommend benchmark FIRST (record baseline) so success criteria can be measured. Planner should commit the baseline numbers in PLAN.md.

5. **Skip-EXIF-in-Android-live-path task** — research found the live path **already** skips EXIF (it goes through `MrzOcr.runTesseract`, not `MrzOcr.scanImage`). The CONTEXT decision was based on an assumption that turned out wrong. Recommend collapsing this "task" into a one-line comment in the live-path code asserting the property, plus a verification check in the plan. No code change needed.

6. **`frame.image` stride assumption** — if Fotoapparat ever delivers padded NV21 buffers, the index math breaks. Recommend a single defensive check at the top of `nv21ToBinaryBitmap` that asserts buffer size and falls back to the old JPEG path if the assertion fails. Planner should explicitly include this fallback as part of the task acceptance criteria so it isn't dropped.

## Sources

### Primary (HIGH confidence)
- Repo source files (verified line-by-line):
  - `android/src/main/kotlin/.../MrzOcr.kt`
  - `android/src/main/kotlin/.../FotoapparatCamera.kt`
  - `android/src/main/kotlin/.../FlutterMrzScannerPlugin.kt`
  - `ios/Classes/MRZScannerView.swift`
  - `ios/Classes/MrzImageOcr.swift`
  - `ios/Classes/CGImage+Orientation.swift`
  - `ios/Classes/SwiftFlutterMrzScannerPlugin.swift`
  - `lib/src/mrz_scanner.dart`
  - `test/static_channel_test.dart`
  - `pubspec.yaml`, `example/pubspec.yaml`, `android/build.gradle`
- `.planning/phases/02-scan-throughput/02-CONTEXT.md` (locked decisions)
- `.planning/REQUIREMENTS.md` (PERF-01/02/03)
- `.planning/ROADMAP.md` (phase success criteria)

### Secondary (MEDIUM confidence — based on training knowledge of well-known Apple/Google APIs)
- Apple Core Image: `CIContext` is thread-safe; reuse recommended.
- Apple Vision: `VNRequest.results` is replaced on each `perform()`; same `VNRequest` instance reusable across serial calls.
- Android `ImageFormat.NV21` layout (Y plane first, full resolution, single channel = grayscale).
- Tesseract 4.x C++ API: `SetImage` may be called repeatedly after `Init`; `End`/`recycle` releases.
- AVFoundation `alwaysDiscardsLateVideoFrames` behavior.

### Tertiary (LOW confidence — verify on first implementation)
- `tesseract4android` (cz.adaptech:tesseract4android:4.1.1) javadoc specifics — confirm `setImage` reuse is supported via the JNI binding (vs. the upstream C++ API allowing it). [ASSUMED]
- Fotoapparat 2.7 `Frame.image` is tightly packed NV21 with no row padding. [ASSUMED]
- SwiftyTesseract concurrent-call safety. [ASSUMED — likely not safe; serializing is the safe default]

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | tesseract4android `TessBaseAPI.setImage` can be called repeatedly without re-init | Tesseract caching plan | Mitigation: if reuse fails, fall back to per-call `init` (no caching). Detectable on first device test. |
| A2 | `setImage` does not retain the Bitmap; caller may recycle immediately | Pitfalls P2 | Mitigation: don't recycle bitmap until after `utF8Text` returns (already the plan). Even if Tesseract retains, no leak — just GC-pressure correctness. |
| A3 | Fotoapparat 2.7 `Frame.image` is tightly packed NV21 (no row padding) | Android YUV plan | Mitigation: runtime size assertion + JPEG-path fallback. |
| A4 | `frame.rotation` rotation direction matches existing `-frame.rotation` semantics | Pitfalls P5 | Mitigation: visual verification on first device run; tunable in 2 lines. |
| A5 | SwiftyTesseract concurrent calls are not safe | Concurrency / iOS | Mitigation: serial queue / lock — defensive default; no perf cost when uncontended. |
| A6 | Synthetic OCR-B-rendered PNG is recognizable by Tesseract `ocrb` traineddata | Benchmark sample | Mitigation: fallback to user-supplied sample. |
| A7 | `MRZScannerView.dispose()` not calling `cameraView.dispose()` is a pre-existing leak (vs. intentional) | Pitfall P6 | Recommend fix; verify with maintainer that it's not an intentional design. |

## Metadata

**Confidence breakdown:**
- Locked decisions / scope: HIGH — CONTEXT.md is explicit.
- Source-line refs and current-state findings: HIGH — verified by reading the files.
- Tesseract / Fotoapparat reuse semantics: MEDIUM — based on widely-documented C++ API behavior; verify on first device build.
- iOS Apple API behavior (Vision, CoreImage): HIGH — well documented.
- Benchmark synthetic sample feasibility: LOW — needs a real run to confirm.

**Research date:** 2026-05-07
**Valid until:** 2026-06-07 (30 days; native pipelines are stable)
