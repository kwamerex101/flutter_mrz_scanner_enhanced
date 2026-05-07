# Phase 1 Discussion Log

## Areas discussed

### MRZ region detection
- **Options presented:** Auto-detect / Caller pre-crops / Optional crop rect arg
- **Selected:** Auto-detect (Recommended)
- **Notes:** iOS already has Vision text-rectangle detection for live frames; reuse it. Android can OCR full image and let `mrz_parser` filter MRZ-shaped lines. Caller passes raw bytes only — no crop knobs.

### API shape
- **Options presented:** Static method on `MRZScanner` / new `MrzImageScanner` class / top-level function
- **Selected:** Static method on `MRZScanner` (Recommended)
- **Notes:** `static Future<MRZFullResult?> MRZScanner.scanImage(Uint8List bytes)`. One import, discoverable, no widget required.

### Input format
- **Options presented:** Bytes only / Bytes or file path / Bytes / file path / asset
- **Selected:** Bytes only (Recommended)
- **Notes:** Single decoding path on each platform. Callers using `image_picker`, `File.readAsBytes()`, asset bundles, or our own `takePhoto()` all produce `Uint8List`.

## Deferred ideas
- Auto-rotation / perspective correction (follow-up phase if needed)
- File-path / asset-key input wrappers (thin Dart wrappers later, no native change)
- Streaming progress callback (not needed for single Future)

## Claude's discretion
- Native channel naming: `mrzscanner_static` (separate from per-widget `mrzscanner_$id`).
- Native returns recognized OCR `String?` to Dart; Dart owns `mrz_parser` invocation, mirroring the live `onParsed` pattern.
- Refactor existing native OCR helpers (`scanMRZ` on Android, OCR-from-CGImage on iOS) to be reachable without a live camera session — exact factoring left to planner.
