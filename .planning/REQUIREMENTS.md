# Requirements

## v1 Requirements

### Image Scanning
- [ ] **SCAN-IMG-01**: User can pass a still image (bytes) to the plugin and receive a parsed `MRZFullResult?`. Reuses the existing native Tesseract pipeline (same `ocrb` trained data, same charset whitelist, same preprocessing) so accuracy matches the live-frame path. Works on both iOS and Android.
- [ ] **SCAN-IMG-02**: When OCR succeeds but the text is not a valid MRZ, the call returns `null` (not an error). When OCR fails for a recoverable reason (e.g. no text found), the call returns `null`. When the call fails for a non-recoverable reason (decode failure, native exception), it surfaces a `PlatformException`.
- [ ] **SCAN-IMG-03**: The image-scan path can be invoked **without** mounting the `MRZScanner` widget — it must work as a static / controller-less call. (Camera-based widget scan must continue to work unchanged.)

### Performance
- [ ] **PERF-01**: Tesseract is initialized at most once per scanning session (live or static), not once per frame/call. On Android, the `TessBaseAPI` instance is cached and reused; on iOS, the `SwiftyTesseract` instance is shared. The cached instance must be properly released when the scanner is torn down (no native-resource leak).
- [ ] **PERF-02**: The live frame loop drops frames while a previous OCR is in flight on both platforms — no coroutine/dispatch backlog accumulation. Behaviorally: under sustained load the scanner produces a stable processed-frame rate and steady memory, instead of growing latency until OOM.
- [ ] **PERF-03**: The Android live frame path no longer round-trips YUV → JPEG → Bitmap. Conversion goes directly from the frame's YUV planes to a Bitmap suitable for OCR (or to grayscale directly), eliminating the JPEG encode/decode pair. iOS removes per-frame allocation of `VNDetectTextRectanglesRequest` and `CIContext`.

### OCR Engine Modernization (still-image path only)
- [ ] **OCR-ENG-01**: On iOS, `MRZScanner.scanImage(bytes)` uses Apple Vision `VNRecognizeTextRequest` (with `recognitionLevel = .accurate`, `usesLanguageCorrection = false`) instead of SwiftyTesseract. The live camera path (`MRZScannerView`) keeps using SwiftyTesseract — only the static path is swapped. The Phase 1 API contract is unchanged (channel name `mrzscanner_static`, method `scanImage`, args `{'bytes': bytes}`, return `MRZFullResult?`).
- [ ] **OCR-ENG-02**: An executable Android plan (`03-ANDROID-PLAN.md`) is written describing the equivalent swap to MLKit on-device text recognition. The plan must be detailed enough to hand to an executor without further research (file paths, line refs, atomic tasks, acceptance checks). Execution is deferred — only the plan is required for this phase.

### Out of Scope (this milestone)
- Auto-rotation of the input image — caller responsible for orientation
- Perspective correction / dewarping
- ML Kit / non-Tesseract engine
- Web platform support
- Batch scanning of multiple images in one call

## Traceability
| REQ-ID | Phase |
|--------|-------|
| SCAN-IMG-01 | Phase 1 |
| SCAN-IMG-02 | Phase 1 |
| SCAN-IMG-03 | Phase 1 |
| PERF-01 | Phase 2 |
| PERF-02 | Phase 2 |
| PERF-03 | Phase 2 |
| OCR-ENG-01 | Phase 3 |
| OCR-ENG-02 | Phase 3 |
