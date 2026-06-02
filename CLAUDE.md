# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Flutter plugin (`flutter_mrz_scanner_enhanced`) that scans the Machine Readable Zone (MRZ) of passports and ID documents on iOS and Android. The package itself is not a runnable app — exercise it through `example/`.

## Common commands

```bash
# Run the example app (this is how you test changes)
cd example && flutter pub get && flutter run

# After bumping iOS deps in the example
cd example/ios && pod install

# Static analysis (uses analysis_options.yaml at repo root)
flutter analyze

# Pre-publish check
flutter pub publish --dry-run
```

iOS deployment target is **13.0** (matches the Flutter 3.41+ floor). There is no automated test suite in this package; verify by running the example app against a real document.

## Architecture

The plugin is a three-layer system: **Dart widget ↔ MethodChannel ↔ native platform view**. The Dart side is mostly a thin shell — all camera capture and OCR happens natively.

### Dart layer ([lib/src/mrz_scanner.dart](lib/src/mrz_scanner.dart))
- `MRZScanner` widget instantiates an `AndroidView` / `UiKitView` and surfaces a `MRZController` via `onControllerCreated`.
- `withOverlay: true` is required — the native side reads the overlay's crop rect to know where the MRZ band sits.
- Controller exposes:
  - `takePhoto({bool crop})` → returns JPEG bytes
  - Callbacks: `onParsed(MRZFullResult)`, `onParsingFailed()`, `onError(String)`, `onDetection()`
- MRZ string parsing is done in Dart by the `mrz_parser` package; OCR is native.

### Two parallel capture paths
1. **Live frame loop (primary scanning path)** — every camera frame is preprocessed and OCR'd. On a successful parse, `onParsed` fires. The user does not "take a picture"; they just hold the document in the overlay until parsing succeeds.
2. **`takePhoto()`** — explicit still capture returning JPEG bytes. **This path does NOT run OCR**; it exists to keep a photo of the document alongside the parsed MRZ. On Android, EXIF orientation is normalized before returning bytes (see commit `ade9059`).

### Android ([android/src/main/kotlin/.../](android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced))
- `FotoapparatCamera.kt` — uses the Fotoapparat library for the camera. `frameProcessor = ::processFrame` runs per frame: crop → grayscale → binary threshold → Tesseract via `TessBaseAPI` (asset `ocrb.traineddata`, whitelist `A-Z 0-9 <`, `PSM_SINGLE_BLOCK`).
- `FlutterMrzScannerPlugin.kt` — registers the platform view and the MethodChannel.
- `takePhoto` flow: `autoFocus().takePicture()` → `normalizeCapturedBitmap` (EXIF rotate) → optional crop → JPEG bytes.

### iOS ([ios/Classes/](ios/Classes))
- `MRZScannerView.swift` — `AVCaptureSession` + `AVCaptureVideoDataOutput`. Per-frame: `VNDetectTextRectanglesRequest` (Vision) locates the MRZ band, then SwiftyTesseract (custom `ocrb` language) does the OCR.
- `SwiftFlutterMrzScannerPlugin.swift` — platform view + MethodChannel wiring.

### Supported MRZ formats
TD1, TD2, TD3, MRV-A, MRV-B (parsed via `mrz_parser`).

## Things to know when changing code

- The OCR engine is **Tesseract on both platforms** (not ML Kit). The `ocrb.traineddata` files are bundled assets; replacing them changes recognition behavior.
- The crop rectangle on the native side is derived from the Flutter overlay's geometry — if you change `camera_overlay.dart`, verify the native crop math still aligns.
- Live-frame OCR and `takePhoto` are independent code paths. A fix to one usually does not transfer; check both when touching image preprocessing or rotation handling.
- This is a fork of the original `flutter_mrz_scanner` package; package name and Android namespace are `flutter_mrz_scanner_enhanced` / `io.github.elmehdaouiahmed.flutter_mrz_scanner_enhanced`.
