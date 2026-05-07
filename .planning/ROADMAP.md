# Roadmap

**3 phases** | **8 requirements** | All v1 requirements covered ✓

| # | Phase | Goal | Requirements | Success Criteria |
|---|-------|------|--------------|------------------|
| 1 | Image-based MRZ scan | Add `scanImage(bytes)` API on iOS, Android, and Dart, reusing the existing Tesseract pipeline | SCAN-IMG-01, SCAN-IMG-02, SCAN-IMG-03 | 4 |
| 2 | Scan throughput | Make live + static paths materially faster: cache Tesseract, throttle frames, eliminate YUV→JPEG→Bitmap roundtrip, plus quick wins | PERF-01, PERF-02, PERF-03 | 5 |
| 3 | Modern OCR engines for `scanImage` | Swap legacy Tesseract for modern neural OCR on the still-image path: iOS uses Apple Vision `VNRecognizeTextRequest`; Android plan written for follow-up MLKit swap | OCR-ENG-01, OCR-ENG-02 | 4 |

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

---

## Phase 3: Modern OCR engines for `scanImage`

**Goal:** The bundled `ocrb.traineddata` is a legacy Tesseract 3 model with no LSTM neural net — accuracy on one-shot still images hits a ceiling that the live path papers over by retrying ~30 frames/sec until check digits validate. Swap the still-image OCR path to a modern neural engine on each platform. Live camera path stays on Tesseract (fine for that use case, no app-size or dependency churn).

**Requirements:** OCR-ENG-01, OCR-ENG-02

**Phase 3a (this phase): iOS** — `MRZScanner.scanImage` on iOS uses `VNRecognizeTextRequest` (Apple Vision) instead of SwiftyTesseract. Free, ~0 MB cost, on-device, materially better on real-world camera photos.

**Phase 3b (deliverable: PLAN.md only, not executed yet): Android** — equivalent swap to MLKit on-device text recognition. Plan written and committed; execution deferred until iOS results are validated.

**Success criteria:**
1. `MRZScanner.scanImage(bytes)` on iOS no longer routes through SwiftyTesseract; it uses `VNRecognizeTextRequest` with `recognitionLevel = .accurate`, `usesLanguageCorrection = false`.
2. Live camera path (`MRZScannerView`) is unchanged — still uses SwiftyTesseract via the existing delegation point.
3. Phase 1 unit test (`test/static_channel_test.dart`) still passes — channel name/method/args/return semantics unchanged.
4. A written `03-ANDROID-PLAN.md` deliverable exists describing the Android MLKit swap as an executable task list (research → tasks → verification).

**UI hint:** no
