# Flutter MRZ Scanner Enhanced 

Based on [![Pub Version](https://img.shields.io/pub/v/flutter_mrz_scanner)](https://pub.dev/packages/flutter_mrz_scanner)

**A community-maintained fork** of the original `flutter_mrz_scanner` package with significant improvements to MRZ scanning reliability and camera UX.

## ✨ Key Enhancements
- **Image-based scanning** — new `MRZScanner.scanImage(Uint8List bytes)` static API parses MRZ from any image (gallery pick, captured photo, asset, etc.) without mounting the camera widget. The still-image path uses modern neural OCR for materially better accuracy on real-world camera photos: **Apple Vision (`VNRecognizeTextRequest`) on iOS** and **Google ML Kit text recognition on Android**. The live camera path keeps using Tesseract on both platforms.
- **Improved text recognition accuracy** through advanced image preprocessing
- **Optimized camera overlay UI** for better user experience
- **Faster scan throughput**
  - `TessBaseAPI` / `SwiftyTesseract` cached per scanning session (no more per-frame init)
  - Live frame loop drops frames while OCR is in flight (no backlog under load)
  - Android live path goes directly from NV21 Y-plane to a thresholded `Bitmap` — JPEG round-trip removed
  - iOS reuses `VNDetectTextRectanglesRequest` and `CIContext` across frames; OCR runs off the sample-buffer queue
- **EXIF orientation handling** for both `takePhoto()` and `scanImage()` — portrait gallery photos OCR upright
- Modernized dependencies and null-safety support
- Improved error handling and validation
- Better platform compatibility

## 🚧 Active Development

As I'm actively using this in production, expect regular updates including:

### Performance Improvements 🚀
- **Flutter Isolate Integration**: Offload heavy image processing and OCR tasks to background isolates for smoother UI performance.
- **Real-Time MRZ Detection**: Implement live feedback for MRZ detection with visual indicators and dynamic UI updates.

### Feature Enhancements ✨
- **Machine Learning Model Optimizations**: Improve OCR accuracy with updated ML models and preprocessing pipelines.
- **Customizable UI Components**: Allow developers to fully customize the camera overlay, scanning UI, and feedback animations.

### Stability & Maintenance 🔧
- **Improved Error Handling**: Better error reporting and recovery mechanisms for edge cases.
- **Cross-Platform Compatibility**: Ensure consistent behavior across iOS, Android, and web platforms.
- **Community-Driven Features**: Prioritize features and fixes based on community feedback.


## 🙏 Acknowledgments
This package builds upon the work of:
- [@olexale](https://github.com/olexale) (Oleksandr Leushchenko) - Original creator
- [@makhosi6](https://github.com/makhosi6) (Makhosandile) - Early contributor
- [@eusopht2021](https://github.com/eusopht2021) - Community contributor

Contributions welcome! Please report issues and feature requests on [GitHub](https://github.com/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced).
### Supported formats:
* TD1
* TD2
* TD3
* MRV-A
* MRV-B

## Usage

### Import the package
Add to `pubspec.yaml`
```yaml
dependencies:
  flutter_mrz_scanner: <latest_version_here>
```
### For iOS
Set iOS deployment target to 12.

The plugin uses the device camera, so do not forget to provide the `NSCameraUsageDescription` in `Info.plist`:
```xml
    <key>NSCameraUsageDescription</key>
    <string>SCANNING MRZ REQUIRE CAMERA PERMISSIONS</string>
```

If you also use `MRZScanner.scanImage()` with a gallery picker (e.g. `image_picker`), add `NSPhotoLibraryUsageDescription`:
```xml
    <key>NSPhotoLibraryUsageDescription</key>
    <string>Pick a passport photo to scan its MRZ.</string>
```

### For Android
Add
```
<uses-permission android:name="android.permission.CAMERA" />
```
to `AndroidManifest.xml`. Camera permission is only required for the live scanner widget — `scanImage()` works without it.

### Live camera scanning — `MRZScanner` widget

Use the `MRZScanner` widget for real-time camera-based scanning:

```dart
MRZScanner(
  withOverlay: true, // Mandatory for proper document cropping
  onControllerCreated: (controller) {
    controller.onParsed = (mrz) {
      // mrz.mrzResult — parsed fields (name, doc number, DOB, expiry, …)
      // mrz.mrz       — raw MRZ string the OCR produced
    };
    controller.onParsingFailed = () { /* keep scanning */ };
    controller.onError = (msg) { /* surface to UI */ };
  },
)
```

The controller also exposes `flashlightOn()`, `flashlightOff()`, `startPreview()`, `stopPreview()`, and `takePhoto({bool crop = true})`.

### Image-based scanning — `MRZScanner.scanImage`

Scan MRZ from any image (gallery pick, file, asset, captured photo) **without mounting the widget**:

```dart
import 'dart:typed_data';
import 'package:flutter_mrz_scanner_enhanced/flutter_mrz_scanner_enhanced.dart';

final Uint8List bytes = await pickedFile.readAsBytes(); // e.g. from image_picker
final result = await MRZScanner.scanImage(bytes);

if (result != null) {
  print(result.mrzResult.givenNames);
  print(result.mrzResult.documentNumber);
} else {
  // OCR found no MRZ, or text wasn't a valid MRZ
}
```

Behavior:
- Returns `MRZFullResult?` — `null` when OCR finds nothing or the text isn't a valid MRZ.
- Throws `PlatformException` only on hard native failures (e.g. undecodable bytes).
- Modern neural OCR per platform — **Apple Vision** on iOS, **Google ML Kit text recognition** on Android. Both run on-device, no network, no model download. The legacy `ocrb`-trained Tesseract pipeline is no longer used for still-image scans (it remains in place for live camera scanning).
- MRZ-shaped lines are filtered + ordered structurally (TD3 line 1 vs line 2 by content, not just spatial position) before being handed to `mrz_parser` — so passport photos parse correctly regardless of EXIF rotation or where Vision/ML Kit happen to emit observations from.
- EXIF-normalized on both platforms — pass raw bytes from `image_picker`/files/assets and the library handles orientation.
- Caller passes raw bytes only; no crop rect, no file path, no asset key.

Refer to the `example/` project for a complete app demonstrating both paths (live camera + image picker).

## Acknowledgements
* [Anna Domashych](https://github.com/foxanna) for helping with [mrz_parser](https://github.com/olexale/mrz_parser) implementation in Dart
* [Anton Derevyanko](https://github.com/antonderevyanko) for hours of Android-related discussions
* [Mattijah](https://github.com/Mattijah) for beautiful [QKMRZScanner](https://github.com/Mattijah/QKMRZScanner) library

## License
`flutter_mrz_scanner_enhanced` is released under a [MIT License](https://opensource.org/licenses/MIT). See `LICENSE` for details.
