# Roadmap

**1 phase** | **3 requirements** | All v1 requirements covered ✓

| # | Phase | Goal | Requirements | Success Criteria |
|---|-------|------|--------------|------------------|
| 1 | Image-based MRZ scan | Add `scanImage(bytes)` API on iOS, Android, and Dart, reusing the existing Tesseract pipeline | SCAN-IMG-01, SCAN-IMG-02, SCAN-IMG-03 | 4 |

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
