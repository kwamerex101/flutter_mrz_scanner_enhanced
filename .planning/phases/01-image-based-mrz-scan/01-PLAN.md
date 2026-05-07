---
phase: 01-image-based-mrz-scan
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/MrzOcr.kt
  - android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FotoapparatCamera.kt
  - android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FlutterMrzScannerPlugin.kt
  - ios/Classes/MrzImageOcr.swift
  - ios/Classes/CGImage+Orientation.swift
  - ios/Classes/MRZScannerView.swift
  - ios/Classes/SwiftFlutterMrzScannerPlugin.swift
  - ios/Classes/FlutterMrzScannerPlugin.m
  - lib/src/mrz_scanner.dart
  - example/pubspec.yaml
  - example/lib/main.dart
  - example/lib/image_scan_page.dart
  - example/ios/Runner/Info.plist
  - test/static_channel_test.dart
autonomous: false
requirements:
  - SCAN-IMG-01
  - SCAN-IMG-02
  - SCAN-IMG-03

must_haves:
  truths:
    - "Caller can call MRZScanner.scanImage(bytes) without ever mounting the MRZScanner widget and receive a MRZFullResult? back."
    - "Existing live-camera scan via the MRZScanner widget still fires onParsed with a valid MRZFullResult, byte-for-byte unchanged behavior."
    - "An image with a valid MRZ band returns a non-null MRZFullResult whose mrz string round-trips through mrz_parser cleanly."
    - "An image with no readable MRZ returns null (not an exception)."
    - "An undecodable byte array surfaces as a PlatformException to the Dart caller."
    - "Both platforms normalize EXIF orientation on input bytes so a portrait image_picker JPEG (Orientation=6) does not OCR sideways."
    - "Native OCR runs off the main thread; the MethodChannel reply is delivered on the main thread."
  artifacts:
    - path: "android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/MrzOcr.kt"
      provides: "Singleton object exposing ensureTrainedData(context), scanImage(context, bytes): String?, preprocess(bitmap), runTesseract(context, bitmap)"
      contains: "object MrzOcr"
    - path: "ios/Classes/MrzImageOcr.swift"
      provides: "Final class with shared singleton; scanImage(data:) throws -> String?; performOcr(on:); preprocess(_:)"
      contains: "final class MrzImageOcr"
    - path: "ios/Classes/CGImage+Orientation.swift"
      provides: "Shared EXIF-rotation helper extracted from MRZScannerView.createMatchingBackingDataWithImage"
      contains: "func applyExifOrientation"
    - path: "lib/src/mrz_scanner.dart"
      provides: "static Future<MRZFullResult?> MRZScanner.scanImage(Uint8List bytes); top-level _splitRecognized helper"
      contains: "static Future<MRZFullResult?> scanImage"
    - path: "test/static_channel_test.dart"
      provides: "Unit test asserting channel name, method name, args shape, success and parse-failure paths"
      contains: "mrzscanner_static"
    - path: "example/lib/image_scan_page.dart"
      provides: "Manual verification page that picks a gallery image and calls MRZScanner.scanImage"
      contains: "MRZScanner.scanImage"
  key_links:
    - from: "lib/src/mrz_scanner.dart MRZScanner.scanImage"
      to: "MethodChannel('mrzscanner_static') -> native scanImage"
      via: "invokeMethod<String?>('scanImage', {'bytes': bytes})"
      pattern: "mrzscanner_static.*scanImage"
    - from: "FlutterMrzScannerPlugin.onAttachedToEngine (Android)"
      to: "MrzOcr.scanImage(context, bytes)"
      via: "MethodChannel handler dispatching on a background Thread, posting result on main Looper"
      pattern: "MrzOcr\\.scanImage"
    - from: "MrzStaticChannel.register (iOS)"
      to: "MrzImageOcr.shared.scanImage(data:)"
      via: "DispatchQueue.global(.userInitiated).async; result delivered on DispatchQueue.main"
      pattern: "MrzImageOcr\\.shared\\.scanImage"
    - from: "FotoapparatCamera live frame path"
      to: "MrzOcr.preprocess + MrzOcr.runTesseract"
      via: "delegating internal calls so live and static paths share one OCR core"
      pattern: "MrzOcr\\.(preprocess|runTesseract)"
    - from: "MRZScannerView.mrz(from:) live path"
      to: "MrzImageOcr.shared.performOcr(on:)"
      via: "delegation; live Vision pipeline left intact, OCR call delegates to shared helper"
      pattern: "MrzImageOcr\\.shared\\.performOcr"
---

<objective>
Add `static Future<MRZFullResult?> MRZScanner.scanImage(Uint8List bytes)` to the
flutter_mrz_scanner_enhanced plugin. Reuse the existing native Tesseract pipelines on
Android and iOS via a NEW global MethodChannel `mrzscanner_static` that does not depend
on a platform view. Live-camera path (`MRZScanner` widget, `MRZController`,
`mrzscanner_$id` channel, `onParsed`/`onError`/`onParsingFailed`) must keep working
byte-for-byte after the refactor.

Purpose: deliver SCAN-IMG-01/02/03. Callers who already use `image_picker`,
`File.readAsBytes`, asset bundles, or `takePhoto()` get MRZ parsing on still images
without mounting the camera widget.

Output:
- New `MrzOcr` Kotlin object + `MrzImageOcr` Swift class (single source of truth for OCR).
- New global MethodChannel `mrzscanner_static` registered in plugin entrypoints on both platforms.
- New Dart static method on `MRZScanner` with mocked-channel unit test.
- Updated example app with an image-pick page for manual verification.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/REQUIREMENTS.md
@.planning/ROADMAP.md
@.planning/phases/01-image-based-mrz-scan/01-CONTEXT.md
@.planning/phases/01-image-based-mrz-scan/01-RESEARCH.md

@lib/src/mrz_scanner.dart
@android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FotoapparatCamera.kt
@android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FlutterMrzScannerPlugin.kt
@ios/Classes/MRZScannerView.swift
@ios/Classes/SwiftFlutterMrzScannerPlugin.swift
@ios/Classes/FlutterMrzScannerPlugin.m

<interfaces>
<!-- Key contracts the executor must respect. -->

Dart (lib/src/mrz_scanner.dart, current public surface to preserve):
```dart
class MRZScanner extends StatelessWidget { /* widget unchanged */ }
class MRZController {
  void Function()? onDetection;
  void Function(MRZFullResult mrz)? onParsed;
  void Function(String text)? onError;
  void Function()? onParsingFailed;
  void flashlightOn();
  void flashlightOff();
  Future<List<int>?> takePhoto({bool crop = true});
  void startPreview({bool isFrontCam = false});
  void stopPreview();
}
class MRZFullResult {
  final String mrz;          // raw recognized OCR text
  final MRZResult mrzResult; // parsed by mrz_parser
}
```
The new API is added to `MRZScanner`, NOT a new class:
```dart
class MRZScanner {
  static Future<MRZFullResult?> scanImage(Uint8List bytes);
}
```

Native -> Dart return contract on `mrzscanner_static.scanImage`:
- Success with text: `String` (raw OCR text, possibly multi-line, possibly garbage; Dart filters/parses)
- No text found: `null`
- Decode/native failure: `PlatformException("SCAN_FAILED" | "BAD_ARGS" | "DECODE_FAILED", message)`

Argument shape: `{'bytes': Uint8List}` -> Android receives `ByteArray`, iOS receives `FlutterStandardTypedData`.
</interfaces>
</context>

<tasks>

<!-- ============================================================
     TASK 1 — Android: extract OCR core into MrzOcr (live path stays green)
     ============================================================ -->
<task type="auto" tdd="false">
  <name>Task 1: Extract Android Tesseract pipeline into MrzOcr singleton; FotoapparatCamera delegates</name>
  <files>
    android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/MrzOcr.kt (new),
    android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FotoapparatCamera.kt (modify)
  </files>
  <behavior>
    - Live frame path keeps producing the SAME OCR output it does today (CONTEXT: byte-for-byte).
    - `MrzOcr.scanImage(context, bytes)` returns recognized OCR text (possibly multi-line) or null when Tesseract finds nothing.
    - `MrzOcr.scanImage` decodes bytes, applies EXIF orientation, applies `preprocess`, runs Tesseract on the FULL preprocessed bitmap (no `calculateCutoutRectCardSize` for static path), recycles intermediate bitmaps in a `finally`.
    - `MrzOcr.ensureTrainedData(context)` is idempotent (skip copy if file exists with non-zero length), thread-safe (`@Volatile` flag + `synchronized`).
    - Tesseract config matches existing live path EXACTLY: language `ocrb`, whitelist `ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789<`, page seg mode `PSM_SINGLE_BLOCK`. Use `recycle()`/`end()` (not just `stop()`) inside the new helper to avoid leaks; LIVE path keeps its existing `stop()` call to honor "no behavior change".
    - Concurrent calls to `scanImage` are safe: a fresh `TessBaseAPI` is instantiated per call.
  </behavior>
  <action>
    Create `MrzOcr.kt` per RESEARCH.md lines 82-130. Implement:
      - `object MrzOcr` with `private const val TESS_LANG = "ocrb"`, `TESS_WHITELIST = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789<"`, `PAGE_SEG_MODE = TessBaseAPI.PageSegMode.PSM_SINGLE_BLOCK`.
      - `@Volatile private var trainedDataReady = false` plus `fun ensureTrainedData(context: Context)` that creates `cacheDir/tessdata/` and copies `assets/ocrb.traineddata` only if the destination file is missing or zero-length. Guard with `synchronized(this)` (RESEARCH.md pitfall #12).
      - `fun preprocess(bitmap: Bitmap): Bitmap` — copy body of FotoapparatCamera.preprocessImage (FotoapparatCamera.kt lines 215-237) verbatim.
      - `internal fun runTesseract(context: Context, bitmap: Bitmap): String?` — body of FotoapparatCamera.scanMRZ (lines 240-250) BUT replace `baseApi.stop()` with `baseApi.recycle()` (or `end()` if recycle is unavailable for the binding). Return null if recognized text is null/blank.
      - `private fun applyExif(decoded: Bitmap, bytes: ByteArray): Bitmap` — port FotoapparatCamera.readExifOrientation (lines 121-133) + applyExifOrientation (lines 135-168) exactly. NO `rotationDegrees` branch — static input has no camera rotation.
      - `fun scanImage(context: Context, bytes: ByteArray): String?` — `ensureTrainedData(context)`; `BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: throw IllegalArgumentException("Unable to decode image bytes")`; `val oriented = applyExif(decoded, bytes)`; `val processed = preprocess(oriented)`; `try { runTesseract(context, processed) } finally { if (processed !== oriented) processed.recycle(); if (oriented !== decoded) oriented.recycle(); decoded.recycle() }`.
    Modify `FotoapparatCamera.kt`:
      - In `init` block (lines 58-62): replace the `getFileFromAssets(...)` call with `MrzOcr.ensureTrainedData(context)`. Keep `cachedTessData` field if other code references it; otherwise delete it.
      - Replace the body of private `preprocessImage(bitmap)` (lines 215-237) with a single line: `return MrzOcr.preprocess(bitmap)`. Keep the function signature/visibility so existing call sites at line 185 don't change.
      - Replace the body of private `scanMRZ(bitmap)` (lines 240-250) with a delegating call: `return MrzOcr.runTesseract(context, bitmap) ?: ""` (live path expects a non-null `String` per current `messenger.invokeMethod("onParsed", fixedMrz)` contract — pass empty string when null so live behavior is identical to today's empty-OCR case).
      - Leave `getFileFromAssets` (lines 260-270) in place but unused, OR delete if no other references — verify with grep.
      - Do NOT touch live `processFrame`, `getImage`, `calculateCutoutRect`, `calculateCutoutRectCardSize`, `normalizeCapturedBitmap`, `applyExifOrientation`, `takePhoto`, flashlight methods. Live path stays byte-for-byte.
  </action>
  <verify>
    <automated>cd example/android && ./gradlew :app:assembleDebug</automated>
  </verify>
  <done>
    `MrzOcr.kt` compiled into the plugin. Android example app builds cleanly. `grep -n "MrzOcr\\." android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FotoapparatCamera.kt` shows live path now delegates to MrzOcr for preprocess + Tesseract. No reference to the removed `cachedTessData`/`getFileFromAssets` paths in `FotoapparatCamera.kt` if those were deleted.
  </done>
</task>

<!-- ============================================================
     TASK 2 — iOS: extract OCR core into MrzImageOcr + EXIF helper
     ============================================================ -->
<task type="auto" tdd="false">
  <name>Task 2: Extract iOS OCR into MrzImageOcr; lift EXIF rotation helper; MRZScannerView delegates</name>
  <files>
    ios/Classes/MrzImageOcr.swift (new),
    ios/Classes/CGImage+Orientation.swift (new),
    ios/Classes/MRZScannerView.swift (modify)
  </files>
  <behavior>
    - Live capture path (`captureOutput` -> Vision -> `mrz(from:)`) keeps emitting the same OCR strings.
    - `MrzImageOcr.shared.scanImage(data:)` decodes Data via `CGImageSourceCreateWithData`, applies EXIF orientation, runs `VNDetectTextRectanglesRequest` with the existing geometric filters (rect width > 0.8 of image width; union height ≤ 0.4 of image height) on the FULL `CGImage`, falls back to OCR'ing the full image if no MRZ region is detected, runs `preprocess` + SwiftyTesseract OCR. Returns recognized String or nil.
    - SwiftyTesseract is lazily instantiated inside `MrzImageOcr.shared` and reused for the lifetime of the app process.
  </behavior>
  <action>
    Create `ios/Classes/CGImage+Orientation.swift`:
      - Move `createMatchingBackingDataWithImage(imageRef:orienation:)` (MRZScannerView.swift lines 412-496) into a free function or `extension CGImage` accessible to both `MRZScannerView` and `MrzImageOcr`. Keep the typo-spelled parameter label `orienation:` only if removing it would force changing the call site at MRZScannerView.swift line 375 — preferred: rename to `orientation:` and update that call site.
      - Add `func applyExifOrientation(to cgImage: CGImage, exifOrientation: CGImagePropertyOrientation) -> CGImage` that maps `CGImagePropertyOrientation` -> `UIImage.Orientation` and calls the rotation helper. Mapping: 1->.up, 2->.upMirrored, 3->.down, 4->.downMirrored, 5->.leftMirrored, 6->.right, 7->.rightMirrored, 8->.left.
    Create `ios/Classes/MrzImageOcr.swift` per RESEARCH.md lines 152-207:
      - `enum MrzImageOcrError: Error { case decodeFailed }`
      - `final class MrzImageOcr` with `static let shared = MrzImageOcr()`.
      - `private lazy var tesseract: SwiftyTesseract` initialized exactly as MRZScannerView.swift line 15: `SwiftyTesseract(language: .custom("ocrb"), bundle: Bundle(url: Bundle(for: MRZScannerView.self).url(forResource: "TraineedDataBundle", withExtension: "bundle")!)!, engineMode: .tesseractLstmCombined)`.
      - `func scanImage(data: Data) throws -> String?`:
          ```
          autoreleasepool {
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { throw MrzImageOcrError.decodeFailed }
            guard let raw = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: true] as CFDictionary) else { throw MrzImageOcrError.decodeFailed }
            let oriented = Self.applyExif(raw, source: src)
            let mrzCrop = detectMrzRegion(in: oriented) ?? oriented   // pitfall #10 fallback
            return performOcr(on: mrzCrop)
          }
          ```
        (Wrap the throwing pieces appropriately so `throws` semantics remain correct outside the autoreleasepool.)
      - `private static func applyExif(_ cgImage: CGImage, source: CGImageSource) -> CGImage` — read `kCGImagePropertyOrientation` from `CGImageSourceCopyPropertiesAtIndex(src, 0, nil)`; if missing or 1, return `cgImage`; otherwise call `applyExifOrientation(to:exifOrientation:)` from `CGImage+Orientation.swift`.
      - `private func detectMrzRegion(in cgImage: CGImage) -> CGImage?` — exact code from RESEARCH.md lines 185-196 (synchronous Vision request; geometric filters; return cropped region or nil).
      - `internal func performOcr(on cgImage: CGImage) -> String?` — body of MRZScannerView.swift `mrz(from:)` lines 111-120 (preprocess UIImage + tesseract.performOCR). Empty/whitespace string -> nil.
      - `internal func preprocess(_ image: UIImage) -> UIImage` — body of MRZScannerView.swift `preprocessImage` lines 124-142.
    Modify `ios/Classes/MRZScannerView.swift`:
      - Line 15 (SwiftyTesseract instance): leave only if needed by other internal code; otherwise replace `tesseract.performOCR(on:)` calls with `MrzImageOcr.shared.tesseract.performOCR(on:)` OR have `mrz(from:)` delegate. Preferred: delete `fileprivate let tesseract = ...` and have `mrz(from:)` call `MrzImageOcr.shared.performOcr(on: cgImage)`.
      - Lines 111-120 (`mrz(from cgImage:)`): replace body with `return MrzImageOcr.shared.performOcr(on: cgImage)`.
      - Lines 124-142 (`preprocessImage(_:)`): replace body with `return MrzImageOcr.shared.preprocess(image)`. Keep function signature for any internal callers.
      - Lines 412-496 (`createMatchingBackingDataWithImage`): delete the local copy (now in `CGImage+Orientation.swift`); update call at line 375 to use the new helper name/parameter label.
      - Do NOT touch `captureOutput`, `documentImage`, `cutoutRect`, `calculateCutoutRect`, `takePhoto`, AVCaptureSession setup, flashlight methods, or any geometry-from-`bounds` code. Live path stays intact.
  </action>
  <verify>
    <automated>cd example/ios && pod install && xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Debug -sdk iphonesimulator -quiet build CODE_SIGNING_ALLOWED=NO</automated>
  </verify>
  <done>
    iOS example builds. `grep -n "MrzImageOcr" ios/Classes/MRZScannerView.swift` shows the live `mrz(from:)` and `preprocessImage(_:)` delegate to the shared singleton. EXIF helper is in `CGImage+Orientation.swift`; only one definition of the rotation function exists in the module.
  </done>
</task>

<!-- ============================================================
     TASK 3 — Register global MethodChannels on both platforms
     ============================================================ -->
<task type="auto" tdd="false">
  <name>Task 3: Register `mrzscanner_static` global MethodChannel on Android and iOS</name>
  <files>
    android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FlutterMrzScannerPlugin.kt (modify),
    ios/Classes/SwiftFlutterMrzScannerPlugin.swift (modify),
    ios/Classes/FlutterMrzScannerPlugin.m (modify)
  </files>
  <behavior>
    - On Android, immediately after the plugin attaches to the engine, `mrzscanner_static` is reachable from Dart with method `scanImage`.
    - On iOS, immediately after `+registerWithRegistrar:`, `mrzscanner_static` is reachable.
    - Calling `scanImage` with `{'bytes': Uint8List}`:
        - returns the recognized OCR `String?` to Dart on success.
        - returns a `PlatformException` on decode failure or native exception (codes: `BAD_ARGS`, `DECODE_FAILED`, `SCAN_FAILED`, or Android additionally `NO_CONTEXT`).
    - Native dispatch is OFF the main thread; the Flutter result callback runs on the main thread.
    - Android `onDetachedFromEngine` clears the static channel handler.
  </behavior>
  <action>
    Android (`FlutterMrzScannerPlugin.kt`) — implement RESEARCH.md lines 226-265 verbatim semantics:
      - Add fields: `private var staticChannel: MethodChannel? = null`, `private var appContext: Context? = null`.
      - In `onAttachedToEngine`: keep existing `registerViewFactory` call (line 23). Then create `MethodChannel(binding.binaryMessenger, "mrzscanner_static")` and set its handler.
      - Handler dispatches `"scanImage"` to `handleScanImage(call, result)`; everything else -> `result.notImplemented()`.
      - `handleScanImage`: pull `call.argument<ByteArray>("bytes")`; if null -> `result.error("BAD_ARGS", "Missing bytes", null)`. If `appContext` null -> `result.error("NO_CONTEXT", "Plugin detached", null)`. Otherwise spawn a worker `Thread { ... }`:
          - `try { val text = MrzOcr.scanImage(ctx, bytes); main.post { result.success(text) } }`
          - `catch (e: IllegalArgumentException) { main.post { result.error("DECODE_FAILED", e.message, null) } }`
          - `catch (e: Throwable) { main.post { result.error("SCAN_FAILED", e.message, null) } }`
        where `main = android.os.Handler(android.os.Looper.getMainLooper())`.
      - Implement `onDetachedFromEngine`: `staticChannel?.setMethodCallHandler(null); staticChannel = null; appContext = null`.

    iOS (`SwiftFlutterMrzScannerPlugin.swift`) — append RESEARCH.md lines 281-303 implementation:
      - Add `@objc public class MrzStaticChannel: NSObject` with `@objc public static func register(with messenger: FlutterBinaryMessenger)`.
      - Inside `register`: create `FlutterMethodChannel(name: "mrzscanner_static", binaryMessenger: messenger)`. Set handler:
          - reject any method != "scanImage" with `FlutterMethodNotImplemented`.
          - cast `call.arguments as? [String: Any]` and `args["bytes"] as? FlutterStandardTypedData`. If missing -> `FlutterError(code: "BAD_ARGS", ...)`.
          - `DispatchQueue.global(qos: .userInitiated).async { do { let text = try MrzImageOcr.shared.scanImage(data: bytes.data); DispatchQueue.main.async { result(text) } } catch MrzImageOcrError.decodeFailed { DispatchQueue.main.async { result(FlutterError(code: "DECODE_FAILED", ...)) } } catch { DispatchQueue.main.async { result(FlutterError(code: "SCAN_FAILED", ...)) } } }`.

    iOS (`FlutterMrzScannerPlugin.m`) — modify `+registerWithRegistrar:` (lines 18-24): after the existing `[registrar registerViewFactory:factory withId:@"mrzscanner"];`, add `[MrzStaticChannel registerWith:registrar.messenger];` (Swift -> ObjC selector will be `registerWith:` based on Swift signature `register(with:)`). Confirm against the generated `-Swift.h` header — adjust selector name if needed.
  </action>
  <verify>
    <automated>cd example && flutter build apk --debug --no-tree-shake-icons && flutter build ios --debug --no-codesign --simulator</automated>
  </verify>
  <done>
    Both platforms compile. `grep -rn "mrzscanner_static" android/src ios/Classes` shows exactly one channel registration on each platform inside the plugin entrypoint (Android: `FlutterMrzScannerPlugin.onAttachedToEngine`; iOS: `MrzStaticChannel.register`). Android `onDetachedFromEngine` nulls the handler.
  </done>
</task>

<!-- ============================================================
     TASK 4 — Dart static API + lifted _splitRecognized + unit test
     ============================================================ -->
<task type="auto" tdd="true">
  <name>Task 4: Add MRZScanner.scanImage Dart API; lift _splitRecognized; add channel unit test</name>
  <files>
    lib/src/mrz_scanner.dart (modify),
    test/static_channel_test.dart (new)
  </files>
  <behavior>
    - `MRZScanner.scanImage(Uint8List bytes)` invokes `MethodChannel('mrzscanner_static').invokeMethod<String>('scanImage', {'bytes': bytes})`.
    - Native returns `String?`. Dart applies the existing `_splitRecognized` normalizer (spaces removed, `«` -> `<`, `DZAK` -> `DZA<`) and `MRZParser.tryParse(lines)`.
    - Returns `MRZFullResult(mrz: rawText, mrzResult: result)` on parse success.
    - Returns `null` if native returned `null`, if `_splitRecognized` produced no lines, or if `MRZParser.tryParse` returned null.
    - `PlatformException` from the channel is NOT caught — it propagates to the caller (per CONTEXT error semantics).
    - The live `MRZController._platformCallHandler` continues to call the SAME `_splitRecognized` (now top-level private) and produces identical behavior to today.
    - Unit test (`test/static_channel_test.dart`) uses `TestDefaultBinaryMessengerBinding` / `setMockMethodCallHandler` (the modern non-deprecated API) to assert: channel name `mrzscanner_static`; method name `scanImage`; arg key `bytes` equals the input Uint8List; returns parsed `MRZFullResult` for a known-good MRZ string; returns `null` for a string that fails parse; returns `null` when handler returns `null`.
  </behavior>
  <action>
    Modify `lib/src/mrz_scanner.dart`:
      - Lift `_splitRecognized` out of `MRZController` (current location lines 110-116) to a top-level private function:
          ```dart
          List<String> _splitRecognized(String recognizedText) {
            final mrzString = recognizedText
                .replaceAll(' ', '')
                .replaceAll('«', '<')
                .replaceAll('DZAK', 'DZA<');
            return mrzString.split('\n').where((s) => s.isNotEmpty).toList();
          }
          ```
        Update the call inside `MRZController._platformCallHandler` (current line 90) to call the top-level function (same name, no receiver). Delete the method from the class.
      - Add a private lazy `MethodChannel` constant at file scope:
          `const MethodChannel _staticChannel = MethodChannel('mrzscanner_static');`
      - Add static method on `MRZScanner` (the existing widget class — DO NOT introduce a new class):
          ```dart
          static Future<MRZFullResult?> scanImage(Uint8List bytes) async {
            final raw = await _staticChannel.invokeMethod<String>(
              'scanImage',
              <String, dynamic>{'bytes': bytes},
            );
            if (raw == null) return null;
            final lines = _splitRecognized(raw);
            if (lines.isEmpty) return null;
            final parsed = MRZParser.tryParse(lines);
            if (parsed == null) return null;
            return MRZFullResult(mrz: raw, mrzResult: parsed);
          }
          ```
        Ensure `import 'dart:typed_data';` is present (or rely on `package:flutter/foundation.dart` which already re-exports `Uint8List` — current file already imports `foundation.dart`, so no change strictly needed; add the explicit import for clarity).
      - Do NOT change the `MRZScanner` widget's `build`, `onPlatformViewCreated`, or `MRZController` public surface. Only `_splitRecognized`'s location moves; its body is identical.

    Create `test/static_channel_test.dart`:
      ```dart
      import 'dart:typed_data';
      import 'package:flutter/services.dart';
      import 'package:flutter_test/flutter_test.dart';
      import 'package:flutter_mrz_scanner_enhanced/flutter_mrz_scanner_enhanced.dart';

      void main() {
        TestWidgetsFlutterBinding.ensureInitialized();
        const channel = MethodChannel('mrzscanner_static');
        final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

        tearDown(() {
          messenger.setMockMethodCallHandler(channel, null);
        });

        test('scanImage targets mrzscanner_static / scanImage with bytes arg', () async {
          MethodCall? captured;
          messenger.setMockMethodCallHandler(channel, (call) async {
            captured = call;
            return null; // OCR found nothing
          });
          final bytes = Uint8List.fromList([1, 2, 3, 4]);
          final result = await MRZScanner.scanImage(bytes);
          expect(result, isNull);
          expect(captured!.method, 'scanImage');
          final args = captured!.arguments as Map;
          expect(args['bytes'], bytes);
        });

        test('scanImage returns null when OCR text fails MRZ parse', () async {
          messenger.setMockMethodCallHandler(channel, (_) async => 'GARBAGE_TEXT_NOT_AN_MRZ');
          final result = await MRZScanner.scanImage(Uint8List(0));
          expect(result, isNull);
        });

        test('scanImage returns MRZFullResult on a valid TD3 MRZ string', () async {
          // Canonical TD3 sample (passport) from mrz_parser test fixtures.
          const td3 =
              'P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<\n'
              'L898902C36UTO7408122F1204159ZE184226B<<<<<10';
          messenger.setMockMethodCallHandler(channel, (_) async => td3);
          final result = await MRZScanner.scanImage(Uint8List(0));
          expect(result, isNotNull);
          expect(result!.mrz, td3);
          expect(result.mrzResult.documentNumber, 'L898902C3');
        });
      }
      ```
      If a different known-good MRZ fixture is more convenient (the `mrz_parser` README has examples), substitute it — the assertion that matters is non-null + a stable field check.

      Add `flutter_test` as a dev_dependency in the plugin's `pubspec.yaml` if not already present (verify via `grep flutter_test pubspec.yaml`).
  </action>
  <verify>
    <automated>flutter test test/static_channel_test.dart</automated>
  </verify>
  <done>
    All three tests pass. `grep -n "_splitRecognized" lib/src/mrz_scanner.dart` shows exactly ONE definition (top-level) and TWO call sites (the static method and `MRZController._platformCallHandler`). Live path still references the same helper.
  </done>
</task>

<!-- ============================================================
     TASK 5 — Example app: image-pick verification page
     ============================================================ -->
<task type="auto" tdd="false">
  <name>Task 5: Add image_picker dep + ImageScanPage to example app for manual verification</name>
  <files>
    example/pubspec.yaml (modify),
    example/lib/main.dart (modify),
    example/lib/image_scan_page.dart (new),
    example/ios/Runner/Info.plist (modify)
  </files>
  <behavior>
    - Example app launches with a chooser screen offering "Live camera scan" (existing flow) and "Pick image from gallery" (new flow).
    - Picking an image, awaiting `MRZScanner.scanImage(bytes)`, then displays either the parsed `mrz` string or the literal text `(no MRZ)` if null.
    - Live camera page is reachable and works exactly as before.
    - iOS app has `NSPhotoLibraryUsageDescription` in `Info.plist` so `image_picker` does not crash.
  </behavior>
  <action>
    `example/pubspec.yaml`: under `dependencies:` add `image_picker: ^1.0.0` (or the latest stable that supports the example's Dart SDK constraint — verify with `flutter pub outdated` if unsure; use `^1.1.2` if 1.0.0 does not resolve). Run `cd example && flutter pub get`.

    `example/lib/image_scan_page.dart` (new):
      ```dart
      import 'package:flutter/material.dart';
      import 'package:flutter_mrz_scanner_enhanced/flutter_mrz_scanner_enhanced.dart';
      import 'package:image_picker/image_picker.dart';

      class ImageScanPage extends StatefulWidget {
        const ImageScanPage({super.key});
        @override
        State<ImageScanPage> createState() => _ImageScanPageState();
      }

      class _ImageScanPageState extends State<ImageScanPage> {
        String? _result;
        bool _busy = false;

        Future<void> _pickAndScan() async {
          setState(() { _busy = true; _result = null; });
          try {
            final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
            if (picked == null) { setState(() => _busy = false); return; }
            final bytes = await picked.readAsBytes();
            final r = await MRZScanner.scanImage(bytes);
            setState(() => _result = r?.mrz ?? '(no MRZ)');
          } catch (e) {
            setState(() => _result = 'Error: $e');
          } finally {
            setState(() => _busy = false);
          }
        }

        @override
        Widget build(BuildContext context) {
          return Scaffold(
            appBar: AppBar(title: const Text('Image scan')),
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ElevatedButton(
                    onPressed: _busy ? null : _pickAndScan,
                    child: Text(_busy ? 'Scanning...' : 'Pick image from gallery'),
                  ),
                  const SizedBox(height: 16),
                  if (_result != null) SelectableText(_result!),
                ],
              ),
            ),
          );
        }
      }
      ```

    `example/lib/main.dart`: add a chooser route. If today's `main.dart` directly launches the camera page, replace its `home:` with a `HomePage` `Scaffold` that contains two `ElevatedButton`s: one navigates to the existing camera page (preserve its widget name), the other navigates to `ImageScanPage`. Do NOT delete or modify the camera page itself.

    `example/ios/Runner/Info.plist`: add inside the top-level `<dict>`:
      ```xml
      <key>NSPhotoLibraryUsageDescription</key>
      <string>Pick a passport photo to scan its MRZ.</string>
      ```

    Run `cd example && flutter pub get`.
  </action>
  <verify>
    <automated>cd example && flutter pub get && flutter analyze</automated>
  </verify>
  <done>
    `flutter analyze` reports no errors in the example app. Both routes exist in `example/lib/main.dart`. `image_picker` is listed under example dependencies. `Info.plist` contains `NSPhotoLibraryUsageDescription`.
  </done>
</task>

<!-- ============================================================
     TASK 6 — Manual end-to-end verification (human checkpoint)
     ============================================================ -->
<task type="checkpoint:human-verify" gate="blocking">
  <what-built>
    - Android `MrzOcr` + iOS `MrzImageOcr` extracted from existing live-camera Tesseract pipelines; live path now delegates to them (CONTEXT requires byte-for-byte identical live behavior).
    - Global `mrzscanner_static` MethodChannel registered on both platforms; Dart `static Future<MRZFullResult?> MRZScanner.scanImage(Uint8List bytes)` added.
    - Example app updated with an ImageScanPage that calls `scanImage` on a gallery-picked image. Dart unit test asserts channel/method/args contract on success and parse-failure paths.
  </what-built>
  <how-to-verify>
    Live-camera regression check (mandatory — CONTEXT forbids regressions):
      1. `cd example && flutter run` on at least ONE physical device (Android OR iOS). Tap "Live camera scan".
      2. Point at a passport's MRZ band. Confirm the existing `onParsed` callback fires and surfaces a parsed result, exactly as it did before this phase.
      3. Confirm flashlight on/off still works and `takePhoto` still returns bytes.
    Static image scan check:
      4. From the home screen, tap "Pick image from gallery".
      5. Pick a clear photo of a passport with a readable MRZ (e.g. the photos saved by `takePhoto` to tempDir, or a sample MRZ image).
      6. Confirm the page displays a non-empty MRZ string (the `mrz` field of `MRZFullResult`). The string should be the same characters Tesseract would produce on the live frame for an equivalent shot.
      7. Pick an image that clearly has NO MRZ (e.g. a landscape photo). Confirm the page shows `(no MRZ)` and the app does NOT crash or throw an unhandled exception.
    EXIF orientation check (catches the most common real-world failure):
      8. Take a portrait-oriented photo of a passport with the device's stock camera (most cameras write `Orientation=6`). Pick that photo. Confirm a non-null parse result. If it returns `(no MRZ)` despite the MRZ being clearly visible upright on screen, EXIF normalization is broken.
    If running on only one platform, document which platform was tested and which is pending in the task summary.
  </how-to-verify>
  <resume-signal>Type "approved" once both live and static paths pass on at least one platform; or describe failures.</resume-signal>
</task>

</tasks>

<verification>
  <phase_level>
    Whole-phase smoke:
      - `flutter analyze` (plugin root + example) — no new warnings.
      - `flutter test` — `test/static_channel_test.dart` passes.
      - `cd example/android && ./gradlew :app:assembleDebug` — Android build green.
      - `cd example/ios && pod install && xcodebuild ... build CODE_SIGNING_ALLOWED=NO` — iOS build green.
      - `grep -rn "mrzscanner_static" lib android ios` — exactly one channel name string per platform native side, plus one per Dart side.
      - `grep -n "_splitRecognized" lib/src/mrz_scanner.dart | wc -l` — three lines (one definition, two call sites).
      - Manual run on a real device per Task 6.
  </phase_level>
</verification>

<success_criteria>
  1. `MRZScanner.scanImage(bytes)` returns a non-null `MRZFullResult` for a clear passport image on both Android and iOS, without the `MRZScanner` widget being mounted (SCAN-IMG-01, SCAN-IMG-03).
  2. `MRZScanner.scanImage(bytes)` returns `null` when OCR finds nothing or text is not a valid MRZ; throws `PlatformException` only on decode/native errors (SCAN-IMG-02).
  3. The example app's existing live-camera page still scans and parses MRZ documents identically to pre-phase behavior.
  4. The Dart unit test in `test/static_channel_test.dart` passes and pins the channel name, method name, and argument shape.
  5. EXIF-rotated `image_picker` photos OCR successfully on both platforms (no sideways-band failure).
</success_criteria>

<output>
After completion, create `.planning/phases/01-image-based-mrz-scan/01-01-SUMMARY.md` per
$HOME/.claude/get-shit-done/templates/summary.md. Capture:
  - What was extracted (`MrzOcr`, `MrzImageOcr`, `CGImage+Orientation`).
  - Channel registration entry points (Android `onAttachedToEngine`, iOS `MrzStaticChannel.register` invoked from `+registerWithRegistrar:`).
  - Dart API location (`MRZScanner.scanImage` static method).
  - Live-path verification result (which platform, what document, what was parsed).
  - Static-path verification result (which platform, EXIF case included).
  - Any deviations from this plan and why.
</output>
