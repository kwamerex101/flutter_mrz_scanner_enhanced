# Phase 1 Context: Image-based MRZ scan

<domain>
Add a controller-less, widget-free path that takes raw image bytes and returns a parsed `MRZFullResult?`, reusing the same Tesseract-based OCR pipeline already proven on live camera frames.
</domain>

<canonical_refs>
- [.planning/PROJECT.md](../../PROJECT.md) — project context, validated/active requirements
- [.planning/REQUIREMENTS.md](../../REQUIREMENTS.md) — SCAN-IMG-01 / 02 / 03 (locked)
- [.planning/ROADMAP.md](../../ROADMAP.md) — phase 1 goal + success criteria
- [lib/src/mrz_scanner.dart](../../../lib/src/mrz_scanner.dart) — existing widget + controller; `_splitRecognized` text normalizer to reuse
- [android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FotoapparatCamera.kt](../../../android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FotoapparatCamera.kt) — Tesseract pipeline (`processFrame`, `scanMRZ(bitmap)`); preprocessing helpers
- [android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FlutterMrzScannerPlugin.kt](../../../android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FlutterMrzScannerPlugin.kt) — plugin registration; place to register the new global MethodChannel
- [ios/Classes/MRZScannerView.swift](../../../ios/Classes/MRZScannerView.swift) — Vision `VNDetectTextRectanglesRequest` + SwiftyTesseract pipeline (`mrz(from:)`)
- [ios/Classes/SwiftFlutterMrzScannerPlugin.swift](../../../ios/Classes/SwiftFlutterMrzScannerPlugin.swift) — iOS plugin registrar; add the global channel here
- `mrz_parser` Dart package — already a dependency; reused as-is for parsing the OCR string
</canonical_refs>

<code_context>
**Reusable assets (must reuse, don't reinvent):**
- Android: `FotoapparatCamera` already has `scanMRZ(bitmap: Bitmap): String` that runs Tesseract on a bitmap and returns the recognized text. Refactor target — make it (or its core) callable independently of an active camera instance, so the static path uses the exact same OCR config (`ocrb`, charset whitelist, `PSM_SINGLE_BLOCK`).
- Android: image preprocessing (grayscale + binary threshold) currently lives inside the frame-processing path. Extract a `prepareBitmapForOcr(Bitmap): Bitmap` helper used by both the live path and the new image path.
- iOS: `MRZScannerView` has the Vision rectangle pipeline + `mrz(from cgImage: CGImage)`. Extract the OCR-from-CGImage path into a static helper or a small `MRZImageOcr` type so it works without an active `AVCaptureSession`.
- Dart: `MRZController._splitRecognized` and the `mrz_parser` invocation are already correct; reuse them in the new static path.

**Existing channel pattern:**
- Per-widget channel name: `mrzscanner_$id` (created in `MRZScanner.onPlatformViewCreated`).
- For the static API we need a NEW global channel that does NOT depend on a platform view being mounted. Naming: `mrzscanner_static` (on both platforms).
- Native returns the raw recognized OCR string to Dart; Dart parses with `mrz_parser`. Mirrors the live `onParsed` pattern.
</code_context>

<decisions>

### MRZ region detection (still images)
**Decision:** Auto-detect on both platforms. iOS keeps using Vision's `VNDetectTextRectanglesRequest` to find the MRZ band (already in the live pipeline). Android runs Tesseract on the full preprocessed bitmap; the resulting text is split into lines, and the Dart side filters to MRZ-shaped lines (`mrz_parser.tryParse` already validates length/checksums).
**Why:** Caller's job ends at "give me an image"; library's job is to find the MRZ. Matches the UX contract callers expect.
**Implication for planner:** No optional `cropRect` parameter on the API. No extra knobs. If accuracy turns out to be poor on full-frame Android OCR, that's a follow-up phase (perspective correction / band detection), not part of this phase.

### Dart API shape
**Decision:** `static Future<MRZFullResult?> MRZScanner.scanImage(Uint8List bytes)`.
**Why:** Single import the user already has; discoverable on the existing public type; no second class to document; no widget required.
**Implication for planner:**
- Add the method on the existing `MRZScanner` class in [lib/src/mrz_scanner.dart](../../../lib/src/mrz_scanner.dart).
- The method opens (or lazily holds) a `MethodChannel('mrzscanner_static')` separate from the per-widget channel.
- It calls a single native method `scanImage` with `{ 'bytes': bytes }`, awaits a `String?` (recognized OCR text) or `null`, runs the existing `_splitRecognized` + `MRZParser.tryParse`, and returns `MRZFullResult?`.

### Input format
**Decision:** `Uint8List` bytes only.
**Why:** One platform code path. Callers using `image_picker`, `File.readAsBytes`, asset bundles, or our own `takePhoto()` all produce `Uint8List` trivially. No second decoding path on iOS/Android.
**Implication for planner:** Native methods accept a single `bytes` arg. No file-path or asset-key overload.

### Error semantics (locked by REQUIREMENTS — not re-discussed)
- OCR succeeds but text is not valid MRZ → `null`
- OCR finds nothing → `null`
- Native exception (decode failure, plugin error) → `PlatformException` propagated to Dart

### No changes to live path
- The existing `MRZScanner` widget, `MRZController`, per-widget MethodChannel, and `onParsed` callback flow MUST remain byte-for-byte unchanged.
- Native refactors to share OCR helpers must keep the live `processFrame` / `captureOutput` paths working with no behavior change. Verifier should re-confirm the example app still scans live.

</decisions>

<deferred>
- Auto-rotation / perspective correction for skewed still images — separate phase if accuracy on full-frame Android OCR proves poor.
- File-path and asset-key input variants — could be added later as thin Dart wrappers around the bytes path without changing native code.
- Streaming progress / per-line callback for image scan — not needed; a single `Future<MRZFullResult?>` is sufficient.
- Replacing Tesseract with ML Kit / on-device LLM — separate effort, out of scope.
</deferred>

<open_questions>
None — gray areas resolved, requirements locked.
</open_questions>

---
*Last updated: 2026-05-07 after discussion*
