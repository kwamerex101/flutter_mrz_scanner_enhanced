# Roadmap

**2 phases** | **6 requirements** | All v1 requirements covered ✓

| # | Phase | Goal | Requirements | Success Criteria |
|---|-------|------|--------------|------------------|
| 1 | Image-based MRZ scan | Add `scanImage(bytes)` API on iOS, Android, and Dart, reusing the existing Tesseract pipeline | SCAN-IMG-01, SCAN-IMG-02, SCAN-IMG-03 | 4 |
| 2 | Scan throughput | Make live + static paths materially faster: cache Tesseract, throttle frames, eliminate YUV→JPEG→Bitmap roundtrip, plus quick wins | PERF-01, PERF-02, PERF-03 | 5 |

---

## Phase 1: Image-based MRZ scan

**Goal:** Allow callers to pass a still image (e.g. from `image_picker`, `takePhoto`, or any byte source) and receive a parsed `MRZFullResult?`, reusing the proven native Tesseract pipeline.

**Requirements:** SCAN-IMG-01, SCAN-IMG-02, SCAN-IMG-03

**Success criteria:**
1. A Dart caller can invoke `MrzScannerEnhanced.scanImage(bytes)` (or equivalent static API) without mounting the `MRZScanner` widget and receive a `MRZFullResult?`.
2. On Android, the call decodes the bytes, runs the same crop/grayscale/threshold preprocessing used for live frames, OCRs with the existing `TessBaseAPI` instance, parses with `mrz_parser`, and returns the result.
3. On iOS, the call converts the bytes to a `CGImage`, runs the same Vision rectangle + SwiftyTesseract pipeline used for live frames, parses with `mrz_parser`, and returns the result.
4. Live-frame scanning via `MRZScanner` widget continues to work unchanged (no regressions in existing camera path).

**UI hint:** no

---

## Phase 2: Scan throughput

**Goal:** Materially reduce time-to-first-parse and increase sustained scan FPS on both platforms by removing per-frame Tesseract reinit, throttling the frame loop while OCR is in flight, eliminating the YUV → JPEG → Bitmap roundtrip on Android, and applying a handful of low-risk quick wins on iOS.

**Requirements:** PERF-01, PERF-02, PERF-03

**Success criteria:**
1. Tesseract (`TessBaseAPI` on Android, `SwiftyTesseract` on iOS) is initialized at most once per scanning session — not once per frame.
2. The live frame loop drops frames while a previous OCR is in flight (no backlog accumulation); reflected in steady memory and no growing coroutine/queue backlog.
3. Android live path no longer encodes YUV → JPEG just to decode back to a `Bitmap`; conversion is direct.
4. iOS reuses `VNDetectTextRectanglesRequest` and `CIContext` across frames instead of allocating per call.
5. No regression in MRZ recognition accuracy or in the static `scanImage` API contract from Phase 1 (unit test still passes; live + static both still parse correctly).

**UI hint:** no
