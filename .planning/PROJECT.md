# Project: flutter_mrz_scanner_enhanced

## What This Is
A Flutter plugin that scans the Machine Readable Zone (MRZ) of passports and identity documents on iOS and Android. Fork of the original `flutter_mrz_scanner` with improved preprocessing, EXIF handling, and modernized deps.

Currently scanning happens **only on the live camera frame loop**. Native code (Tesseract with the `ocrb` trained data) processes every frame; on a successful parse, the Dart side fires `onParsed(MRZFullResult)`.

## Core Value
Reliably extract MRZ fields (name, doc number, DOB, expiry, etc.) from a passport/ID. The single thing that must work is: **given a clear view of the MRZ band, return a parsed MRZFullResult.**

## Context
- Plugin: Dart shell (`lib/src/mrz_scanner.dart`) over native platform views.
- Android: [FotoapparatCamera.kt](android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FotoapparatCamera.kt) — Fotoapparat + Tesseract `TessBaseAPI`.
- iOS: [MRZScannerView.swift](ios/Classes/MRZScannerView.swift) — AVCaptureSession + Vision (`VNDetectTextRectanglesRequest`) + SwiftyTesseract.
- Parser: `mrz_parser` Dart package validates/parses recognized text.
- `takePhoto()` already exists but only returns JPEG bytes — it does not run OCR.

## Requirements

### Validated (from existing code)
- ✓ Live camera frame OCR with parsed callback — existing
- ✓ Camera overlay with crop region — existing
- ✓ `takePhoto()` returning JPEG bytes (Android EXIF normalized) — existing
- ✓ TD1 / TD2 / TD3 / MRV-A / MRV-B parsing via `mrz_parser` — existing

### Active
- [ ] **SCAN-IMG-01**: Add ability to scan MRZ from a still image (bytes) supplied by the caller, reusing the existing Tesseract pipeline on both platforms. Returns `MRZFullResult?` like the live path.

### Out of Scope (this milestone)
- Web platform support — native plugins not built for web
- Replacing Tesseract with ML Kit — separate effort, keep OCR engine stable
- Auto-rotation / perspective correction — could be a follow-up if accuracy is poor

## Key Decisions
| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Reuse native Tesseract pipeline (Option 1) for image scan | Same trained data + preprocessing already validated on frames; avoids parallel Dart-side OCR | Pending |
| Single MethodChannel call `scanImage(bytes, crop)` | Mirrors `takePhoto` shape; no platform view required | Pending |

---
*Last updated: 2026-05-07 after initialization*
