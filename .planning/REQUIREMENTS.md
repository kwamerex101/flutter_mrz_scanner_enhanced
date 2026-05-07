# Requirements

## v1 Requirements

### Image Scanning
- [ ] **SCAN-IMG-01**: User can pass a still image (bytes) to the plugin and receive a parsed `MRZFullResult?`. Reuses the existing native Tesseract pipeline (same `ocrb` trained data, same charset whitelist, same preprocessing) so accuracy matches the live-frame path. Works on both iOS and Android.
- [ ] **SCAN-IMG-02**: When OCR succeeds but the text is not a valid MRZ, the call returns `null` (not an error). When OCR fails for a recoverable reason (e.g. no text found), the call returns `null`. When the call fails for a non-recoverable reason (decode failure, native exception), it surfaces a `PlatformException`.
- [ ] **SCAN-IMG-03**: The image-scan path can be invoked **without** mounting the `MRZScanner` widget — it must work as a static / controller-less call. (Camera-based widget scan must continue to work unchanged.)

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
