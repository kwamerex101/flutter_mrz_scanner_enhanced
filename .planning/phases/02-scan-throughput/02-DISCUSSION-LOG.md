# Phase 2 Discussion Log

## Areas discussed

### Quick wins
- **Selected:** Include all 4 (Recommended)
- **Notes:** Reuse `VNDetectTextRectanglesRequest`, cache `CIContext`, skip EXIF in live Android path, conditional resize in iOS `takePhoto`. Low risk, ~1-2 hr extra.

### Android YUV pipeline approach
- **Selected:** Pure-Kotlin YUV → RGB (Recommended)
- **Notes:** No new native dep. Specifically, read directly from the NV21 Y plane (already grayscale) to skip both the JPEG roundtrip and one preprocess Bitmap. RenderScript only as fallback.

### Frame throttling strategy
- **Selected:** Drop while OCR in flight (Recommended)
- **Notes:** Android `AtomicBoolean`; iOS `DispatchSemaphore`. Simplest, lowest memory.

### Benchmark / regression test
- **Selected:** Full benchmark harness
- **Notes:** User wants measurable proof. Will run against the static `scanImage` path (shared OCR core with live). PLAN must capture baseline numbers before changes and after-numbers in SUMMARY.

## Deferred ideas
- Adaptive FPS-targeted throttling.
- libyuv / NEON / RenderScript optimizations.
- Android Vision-based MRZ band detection (mirror iOS).
- CI-integrated continuous benchmark.

## Claude's discretion
- Static-path Tesseract instance kept app-lifetime (no recycle between calls); live-path instance recycled on camera stop.
- Live path uses `frame.rotation` directly (skip EXIF). Static path keeps EXIF normalization.
- Benchmark format: TBD by planner — preferably `flutter test` or `integration_test` runnable on a device, but a Dart timing wrapper is acceptable if integration setup proves heavy.
