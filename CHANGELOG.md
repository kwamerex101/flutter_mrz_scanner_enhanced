# 3.1.4

- 🧭 Android photo orientation fix:
  - `takePhoto()` now reads EXIF orientation from the captured JPEG bytes and
    normalizes pixel orientation before returning bytes to Flutter.
  - Falls back to Fotoapparat `rotationDegrees` only when EXIF orientation is
    unavailable/normal.
  - Reduces upside-down passport/document images on manufacturer-specific
    Android camera implementations.
- 🤖 Android: NV21 portrait-frame rotation index out-of-bounds fix
  (live OCR no longer crashes on certain devices).
- 🤖 Android: drop unresolved `TessBaseAPI.end()` call — not exposed by the
  tesseract4android binding.
- 🍏 iOS `scanImage` now uses Apple Vision (`VNRecognizeTextRequest`)
  instead of SwiftyTesseract — materially better OCR on real-world photos.
- 🤖 Android `scanImage` now uses ML Kit Text Recognition (latin model)
  with structural line sorting, in place of legacy Tesseract on still images.
- 🖥️ iOS build: works on Apple Silicon (M-series) Mac simulators via Rosetta
  fallback (SwiftyTesseract 3.1.3 still ships only an Intel iOS-simulator
  slice). Plugin podspec deployment target bumped to iOS 13.0 to match the
  Flutter 3.41+ floor; obsolete `EXCLUDED_ARCHS=i386` removed; orphan
  `ios/flutter_mrz_scanner.podspec` deleted.

# 3.1.3

- 🛠️ Fixed: Resolved an app crash issue in version 3.1.2. Apologies for not testing on a real device prior to release.

## 3.1.2


## 3.1.1

- 🚀 Update: Added Coroutine Support for Async MRZ OCR

- 🔄 Changes Made
- Converted heavy MRZ processing to run off the UI thread using Kotlin coroutines.
- Matches Dart's isolate behavior for performance and responsiveness.
- Ensures camera and UI remain smooth during OCR

- ⚙️ Benefits

- Avoids UI freezes during OCR
- Improves overall performance
- Keeps native processing consistent with Dart isolate logic


## 3.1.0

- Temporarily disabled the Document Crop feature due to issues with document size inconsistencies.
- Added a feedback mechanism run /example `camera_page.dart` to view it,used for real-time interaction, providing users with updates instead of displaying a static loading screen.
- Implemented MRZ character replacement to address known OCR detection issues.
- Upgraded Java version to 17 to ensure compatibility with Flutter.

(by @ELMEHDAOUIAhmed)

## 3.0.9

-Enhanced iOS implementation to align with the Android improvements.
-Further testing is needed—unfortunately, I can't test it on iOS. If anyone with an iOS device could help and get in touch, I'd really appreciate it. You can find my contact details on my GitHub page.

(by @ELMEHDAOUIAhmed)
## 3.0.8

# MRZ Cropping Enhancement  
**Unified Function:** Introduced a single function, `calculateCutoutRect(Bitmap bitmap, Boolean cropToMRZ)`, which now supports two cropping modes:

- **Document Crop:** When `cropToMRZ` is `false`, the image is cropped to the full document area with a 10% margin expansion (adjustable if needed; change `val marginPercentage = 0.1`, where `0.1` is 10%).  
- **MRZ Crop:** When `cropToMRZ` is `true`, the image is cropped to only the MRZ area (35% of the document frame's height), accurately matching the measurements from the Flutter overlay.

# Improved Accuracy  
**Consistent Document Ratio:** The cropping calculations now use the same document frame ratio (86/55) and center the document area within the bitmap, ensuring consistent results across both native Android and Flutter overlays.


- val cropped = calculateCutoutRect(rotated, true) // use false if you don't want to crop to MRZ area

# Bug Fixes
Correct Cropping Values: Fixed issues where incorrect cropping values might have been applied, ensuring the correct area is captured for MRZ scanning.

Enjoy the enhanced MRZ scanning functionality!

(by @ELMEHDAOUIAhmed)

## 3.0.7

improved performance, and adjusted document size, also added 10% margin to expand the crop region (10% extra on each side) (margin of error)

## 3.0.6

## 3.0.5

* updated README file

## 3.0.5

* missing package import fix

## 3.0.4

* missing package import fix

## 3.0.3

* missing package import fix

## 3.0.2
* Path error fix
  - Fixed path issue when importing package

(by @ELMEHDAOUIAhmed my apologies, trying to always on the lookout for issues)

## 3.0.1
* Path error fix
  - Fixed path issue when importing package

(by @ELMEHDAOUIAhmed)

## 3.0.0

* **OCR Optimization**: Implemented character whitelisting for MRZ-specific characters (`ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789<`)
* **Image Processing Enhancements**:
  - Improved document cropping accuracy
  - Added grayscale conversion pipeline
  - Optimized binarization thresholds for better text recognition
* **Camera Improvements**:
  - Upgraded Fotoapparat implementation with better focus handling
  - Enhanced frame processing reliability
* **Overlay UI Updates**:
  - Added dynamic scanning guidance indicators
  - Improved aspect ratio handling for different devices
* **Validation System**:
  - Implemented MRZ checksum verification
  - Added error correction heuristics
* **Dependency Updates**:
  - Upgraded Tesseract OCR to latest stable version
  - Migrated to latest Kotlin Gradle plugin
  - Updated Android target SDK to 34
* **Breaking Change**: Requires minimum Flutter 3.16.0

(by @ELMEHDAOUIAhmed)


## 2.1.1

* Add namespace (by @makhosi6)

## 2.1.0

* Support for Flutter 3.0.5 (by @dadagov125)

## 2.0.1

* Fix : Android crash (by @eusopht2021)

## 2.0.0

* Fix : iOS compiling errors for iOS 15 (by @gdaguin)
* Improvements : on Android, the camera is now focusing automatically (by @gdaguin)
* Port to null safety

## 1.0.0
* Android version redeveloped with Fotoapparat library
* Add overlay widget
* Flashlight on/off
* Take a photo

## 0.7.1

* Provide possibility to disable overlay

## 0.7.0

* First public version with basic iOS and Android scanners
