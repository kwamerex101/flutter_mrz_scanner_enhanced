# Phase 2 Context: Scan throughput

<domain>
Reduce time-to-first-parse and increase sustained scan FPS on both platforms by:
1. Caching Tesseract / SwiftyTesseract for the lifetime of a scanning session.
2. Adding frame-drop throttling when OCR is in flight (Android + iOS).
3. Eliminating the YUV → JPEG → Bitmap roundtrip in the Android live path.
4. Reusing iOS Vision request and `CIContext` instead of allocating per frame.
5. Skipping unnecessary EXIF / resize work where data is already known.
6. Adding a benchmark harness to prove the wins are real.
</domain>

<canonical_refs>
- [.planning/REQUIREMENTS.md](../../REQUIREMENTS.md) — PERF-01 / 02 / 03
- [.planning/ROADMAP.md](../../ROADMAP.md) — Phase 2 success criteria
- [.planning/phases/01-image-based-mrz-scan/01-CONTEXT.md](../01-image-based-mrz-scan/01-CONTEXT.md) — prior decisions; Phase 2 must NOT regress the SCAN-IMG-* contract
- [android/.../MrzOcr.kt](../../../android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/MrzOcr.kt) — `runTesseract` (lines 101-117) creates a new `TessBaseAPI` every call — primary fix target for PERF-01
- [android/.../FotoapparatCamera.kt](../../../android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FotoapparatCamera.kt) — `processFrame` (176-193), `getImage` YUV→JPEG→Bitmap (195-202), `preprocessImage` two-bitmap allocation
- [android/.../FlutterMrzScannerPlugin.kt](../../../android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FlutterMrzScannerPlugin.kt) — static channel dispatch (must continue to work after Tesseract caching change)
- [ios/Classes/MRZScannerView.swift](../../../ios/Classes/MRZScannerView.swift) — `captureOutput` per-frame loop; `VNDetectTextRectanglesRequest` allocation site (~line 297); `takePhoto` resize/EXIF (330-373)
- [ios/Classes/MrzImageOcr.swift](../../../ios/Classes/MrzImageOcr.swift) — `CIContext(options: nil)` on every call (~line 87); SwiftyTesseract instance lifecycle
- [test/static_channel_test.dart](../../../test/static_channel_test.dart) — must still pass after refactors

**Audit reference:** see prior assistant audit (in session) — 13 hot spots; this phase tackles the top 3 + 4 quick wins + a benchmark.
</canonical_refs>

<code_context>
**Confirmed-from-source bottlenecks:**
- `MrzOcr.runTesseract` instantiates `TessBaseAPI`, calls `init()`, `setVariable()`, sets `pageSegMode`, `setImage()`, reads `utF8Text`, then `recycle()` — all per call. The `init()` step reloads `ocrb.traineddata` from cacheDir each time.
- `FotoapparatCamera.processFrame` calls `scope.launch { scanMRZ(...) }` per frame with no in-flight check. Coroutines accumulate.
- `getImage()` builds a `YuvImage`, calls `compressToJpeg(rect, 100, out)` (quality 100!), then decodes the JPEG back into a `Bitmap`.
- `preprocessImage` allocates two ARGB_8888 bitmaps (grayscale + threshold) and walks all pixels in Kotlin.
- iOS `MRZScannerView.captureOutput` does similar per-frame allocations of Vision requests.
- `MrzImageOcr` builds a fresh `CIContext` each call.

**Constraints from Phase 1:**
- Both `FotoapparatCamera` (live) and the static `mrzscanner_static` channel call into `MrzOcr`. Caching must work for BOTH paths.
- Live path expects `recycle()` semantics on session stop; static path is one-shot.
- `test/static_channel_test.dart` mocks the channel — refactors must not break the channel name, method name, or args shape.
</code_context>

<decisions>

### Tesseract caching strategy
**Decision:** Cache one `TessBaseAPI` per scanning session.
- **Live path:** `FotoapparatCamera` owns a single `TessBaseAPI` initialized when the camera starts and recycled when the camera stops. Frame OCR reuses the cached instance via `setImage` + `utF8Text`.
- **Static path:** `MrzOcr` keeps a lazily-initialized, synchronized cached instance keyed by traineddata path. First `scanImage` call triggers init; subsequent calls reuse. The cached instance is NOT recycled between calls (it lives for the app lifetime, like the trained-data cache already does).
- iOS: `MrzImageOcr.shared` already keeps `SwiftyTesseract` as a stored property — confirm it's actually reused and remove any unintended re-init paths.

**Why:** `TessBaseAPI.init()` is dominant per-frame cost; reuse is the single biggest win.
**Implication for planner:** Add `TessBaseAPI` ownership in `FotoapparatCamera`. Refactor `MrzOcr` to expose `runTesseract(bitmap, baseApi)` and a separate `getOrInitSharedBaseApi(context)` for the static path. `recycle()` happens on camera stop (live) or never (static, app-lifetime cache).

### Frame throttling
**Decision:** Drop-while-busy on both platforms.
- **Android:** `AtomicBoolean ocrInFlight` in `FotoapparatCamera`. `processFrame` early-returns if true; sets true on `scope.launch`, sets false in a `finally`.
- **iOS:** `DispatchSemaphore(value: 1)` in `MRZScannerView`. `captureOutput` does `tryWait`; skips frame if semaphore busy.

**Why:** Simplest, lowest memory, eliminates backlog; known pattern.
**Implication for planner:** No queueing, no buffering. The most-recent successfully-OCR'd frame wins.

### Android YUV pipeline
**Decision:** Pure-Kotlin / Android-native conversion. Use `android.graphics.YuvImage` only when needed for cropping; otherwise use direct NV21 → grayscale conversion (Y plane is already grayscale — we don't need a Bitmap at all for thresholding).
- Even simpler optimization: since preprocessing converts to grayscale anyway, **read directly from the Y plane of the NV21 buffer** to a single `IntArray` / `ByteArray`, threshold in-place, write to a single `ARGB_8888 Bitmap` for Tesseract `setImage`. Skip JPEG entirely.
- Fall back to `RenderScript` only if the pure-Kotlin conversion is itself a bottleneck after the Tesseract cache fix lands (which it likely won't be).

**Why:** No new native dep; correctness easy to verify; single-pass eliminates two intermediate bitmaps AND the JPEG roundtrip.
**Implication for planner:** Refactor `getImage` + `preprocessImage` into a single `nv21ToBinaryBitmap(frame, rotation)` helper. Live path uses it directly. Static path keeps the existing `BitmapFactory.decodeByteArray + applyExif + preprocess` flow because it doesn't have NV21 — only Bitmap.

### Quick wins (all four included)
1. **iOS `VNDetectTextRectanglesRequest` reuse** — store as a property of `MRZScannerView`; reuse with `request.cancel()` between frames if needed.
2. **iOS `CIContext` cache** — `MrzImageOcr` keeps a lazy-static shared `CIContext`.
3. **Android EXIF skip in live path** — `FotoapparatCamera`'s live path already gets `frame.rotation`; do not also call `readExifOrientation` on its way through `MrzOcr`. Static `scanImage` path keeps EXIF.
4. **iOS `takePhoto` conditional resize** — skip the unconditional 720×1280 resize when image is already smaller; skip EXIF rotation when `Orientation == .up`.

### Benchmark harness
**Decision:** Full benchmark harness for the static path (Dart).
- Add `test/perf/scan_image_bench.dart` (or under `benchmark/`) that runs `MRZScanner.scanImage(bytes)` on a fixed bundled MRZ sample image, N iterations, reports min / p50 / p99 / mean.
- Live-path benchmarking is harder (needs a real camera); the user verifies live perf manually. The static benchmark is the regression guard for the OCR core, which is shared by both paths.
- The benchmark **runs against the device/emulator** (it's an integration-style test invoking `flutter test integration_test/...` or just `flutter test` if MethodChannel can be mocked with a real Tesseract). If full integration setup is too heavy, a "fake-but-realistic" Dart-side timing wrapper around the channel call is acceptable as long as it exercises the actual native path on the device.

**Why:** User explicitly chose this; provides measurable proof of the wins.
**Implication for planner:** Add benchmark scaffolding under `benchmark/` or `integration_test/`. Document baseline numbers in PLAN.md before changes; report after-numbers in SUMMARY.md.

### Non-goals (locked out)
- ML Kit / non-Tesseract engine swap.
- libyuv / NDK native deps.
- Android RenderScript (deprecated); only acceptable as an emergency fallback.
- Adaptive throttling (over-engineered for this phase).
- Web platform.

</decisions>

<deferred>
- Adaptive throttling that targets a specific FPS budget — only if "drop while busy" proves too aggressive in practice.
- libyuv / NEON conversion — only if pure-Kotlin YUV→grayscale is measurably the next bottleneck after the Tesseract fix.
- Single-pass NEON preprocessing — same condition.
- Vision-based MRZ band detection on Android (mirror iOS) — separate phase if accuracy of full-image OCR proves insufficient on slow phones.
- Continuous benchmark in CI — add later when there's CI infra.
</deferred>

<open_questions>
None — gray areas resolved. Research will confirm whether pure-Kotlin NV21 conversion is straightforward enough to land in this phase or needs `RenderScript` fallback.
</open_questions>

---
*Last updated: 2026-05-07 after discussion*
