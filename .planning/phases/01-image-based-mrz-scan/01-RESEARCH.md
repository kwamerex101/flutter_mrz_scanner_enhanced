# Phase 1: Image-based MRZ scan — Research

**Researched:** 2026-05-07
**Domain:** Flutter plugin native interop (Android Tesseract + iOS Vision/SwiftyTesseract) + new global MethodChannel
**Confidence:** HIGH (codebase verified directly; Flutter MethodChannel patterns are standard)

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **MRZ region detection:** Auto-detect on both platforms. iOS keeps Vision `VNDetectTextRectanglesRequest`. Android runs Tesseract on the full preprocessed bitmap; Dart filters lines via `mrz_parser.tryParse`. No `cropRect` parameter.
- **Dart API shape:** `static Future<MRZFullResult?> MRZScanner.scanImage(Uint8List bytes)` on the existing `MRZScanner` class in `lib/src/mrz_scanner.dart`. Lazy `MethodChannel('mrzscanner_static')`. Calls native `scanImage` with `{'bytes': bytes}`, awaits `String?`, runs existing `_splitRecognized` + `MRZParser.tryParse`, returns `MRZFullResult?`.
- **Input format:** `Uint8List` only. No file-path / asset-key overload.
- **Error semantics:** invalid MRZ → `null`; OCR finds nothing → `null`; native exception → `PlatformException`.
- **No changes to live path:** widget, controller, per-widget channel, `onParsed` byte-for-byte unchanged. Refactors must keep `processFrame` / `captureOutput` working.

### Claude's Discretion
- Internal native factoring (where to hoist Tesseract init, helper class names).
- Threading model (background dispatch + main-thread reply).
- EXIF handling for arbitrary input bytes (recommend reuse).

### Deferred Ideas (OUT OF SCOPE)
- Auto-rotation / perspective correction.
- File-path / asset-key Dart wrappers.
- Streaming / per-line callbacks.
- ML Kit / non-Tesseract engine.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| SCAN-IMG-01 | Scan still image bytes, reuse Tesseract pipeline, both platforms | Native pipeline reuse plan (below) |
| SCAN-IMG-02 | Invalid MRZ → null; OCR empty → null; decode/native error → PlatformException | Threading model + error mapping |
| SCAN-IMG-03 | Works without mounting `MRZScanner` widget | Plugin registration sections (global channel registered in `onAttachedToEngine` / `register`) |
</phase_requirements>

## Summary

The static `scanImage` path can be implemented with **minimal native refactoring** because the OCR core on each platform is already self-contained:

- **Android:** `FotoapparatCamera.scanMRZ(bitmap)` (lines 240–250) and `preprocessImage(bitmap)` (lines 215–237) are pure functions of a `Bitmap`. They depend only on `context.cacheDir/tessdata/ocrb.traineddata`, which `getFileFromAssets` (lines 260–270) extracts on the first `FotoapparatCamera` ctor call. We extract these into a new `MrzOcr` object (Kotlin `object` singleton) and call it from a global MethodChannel registered in `FlutterMrzScannerPlugin.onAttachedToEngine`.
- **iOS:** `MRZScannerView.mrz(from: CGImage)` (lines 111–120) and `preprocessImage(_:)` (lines 124–142) are likewise pure of `cgImage`. The `SwiftyTesseract` instance is per-view (line 15) but cheap to instantiate; we extract into a small `MrzImageOcr` enum/struct that owns its own lazily-initialized SwiftyTesseract, and run the same Vision rectangle pass over the input `CGImage`. Register a global `FlutterMethodChannel` in `FlutterMrzScannerPlugin.registerWithRegistrar`.
- **Dart:** Add `static Future<MRZFullResult?> scanImage(Uint8List bytes)` on the `MRZScanner` class. Reuse the exact `_splitRecognized` logic via a top-level helper (or expose it). Return `null` on missing/invalid; let `PlatformException` propagate.

**Primary recommendation:** Extract a Kotlin `object MrzOcr` and a Swift `enum MrzImageOcr`, both lazily initialized on the first `scanImage` call. Register one new global MethodChannel `mrzscanner_static` per platform in the plugin's existing entry points. Keep all live-frame code paths byte-for-byte identical by having the live path call the same extracted helpers (drop-in replacement of the private functions).

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Receive bytes from caller | Dart (`MRZScanner.scanImage`) | — | Public API surface |
| Decode bytes → bitmap/CGImage | Native (Android `BitmapFactory`, iOS `CGImageSourceCreate*`) | — | Avoids re-encoding round-trip; OCR engines are native |
| EXIF normalization | Native | — | Already implemented for `takePhoto` on Android; reuse |
| Preprocessing (grayscale + threshold) | Native (existing helpers) | — | Bit-identical to live path |
| MRZ region detection | iOS: Vision; Android: full-frame OCR | — | Locked decision |
| OCR | Native Tesseract | — | Locked decision |
| Text → MRZ parsing | Dart (`MRZParser.tryParse`) | — | Already used in live path |
| Threading | Native dispatch off main thread; reply on main | Dart awaits the future | Standard MethodChannel pattern |

## Native pipeline reuse plan

### Android — Tesseract extraction

**Where Tesseract lives today** (`android/src/main/kotlin/.../FotoapparatCamera.kt`):
- `init` block lines 58–62: copies `ocrb.traineddata` from assets to `context.cacheDir/tessdata/` on every `FotoapparatCamera` instance creation. Cached path stored in `cachedTessData`.
- `getFileFromAssets` lines 260–270: actual asset → cache copy. **Bug-adjacent:** runs unconditionally on every plugin instance (overwrites file each time). Acceptable; we will keep this behavior in the extracted helper but make it idempotent (skip copy if file exists with non-zero size).
- `scanMRZ(bitmap)` lines 240–250: instantiates a fresh `TessBaseAPI` per call, `init(cacheDir, "ocrb")`, sets whitelist `"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789<"`, `pageSegMode = PSM_SINGLE_BLOCK`, runs OCR, calls `baseApi.stop()`. **Note:** `stop()` does not release native resources fully — `recycle()` (a.k.a. `end()`) would; minor leak, not new to this phase.
- Constant `DEFAULT_PAGE_SEG_MODE = TessBaseAPI.PageSegMode.PSM_SINGLE_BLOCK` line 31.

**Preprocessing** lives in `preprocessImage(bitmap)` lines 215–237: full-image grayscale via `ColorMatrix(setSaturation(0))` + per-pixel threshold at 128. Pure function of bitmap; no overlay/crop coupling here.

**Crop coupling — important for "auto-detect on Android = OCR full image":**
- `processFrame` (lines 180–197) does: `getImage(frame)` → `calculateCutoutRectCardSize(bitmap, true)` (lines 332–364, with `cropToMRZ=true` → bottom 40% of the document frame, ~the MRZ band) → `preprocessImage` → `scanMRZ`.
- The live path is therefore *not* "OCR full image" — it crops to the MRZ band using overlay-derived geometry. The CONTEXT.md decision says the static path runs "Tesseract on the full preprocessed bitmap" (i.e. `preprocessImage(decodedFullBitmap)` only — skip `calculateCutoutRectCardSize`). That is the intended divergence: caller provides a tightly-framed image, we don't second-guess where the band is.
- ✅ Apply `preprocessImage` to the full input bitmap.
- ❌ Do NOT call `calculateCutoutRectCardSize` for the static path.

**Recommended factoring:**

Create new file: `android/src/main/kotlin/io/github/elmehdaouiahmed/flutter_mrz_scanner_enhanced/MrzOcr.kt`

```kotlin
package io.github.elmehdaouiahmed.flutter_mrz_scanner_enhanced

import android.content.Context
import android.graphics.*
import androidx.exifinterface.media.ExifInterface
import com.googlecode.tesseract.android.TessBaseAPI
import java.io.ByteArrayInputStream
import java.io.File

object MrzOcr {
    private const val TESS_LANG = "ocrb"
    private const val TESS_WHITELIST = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789<"
    private val PAGE_SEG_MODE = TessBaseAPI.PageSegMode.PSM_SINGLE_BLOCK

    @Volatile private var trainedDataReady = false

    fun ensureTrainedData(context: Context) {
        if (trainedDataReady) return
        synchronized(this) {
            if (trainedDataReady) return
            val dir = File(context.cacheDir, "tessdata").apply { mkdirs() }
            val file = File(dir, "$TESS_LANG.traineddata")
            if (!file.exists() || file.length() == 0L) {
                file.outputStream().use { out ->
                    context.assets.open("$TESS_LANG.traineddata").use { it.copyTo(out) }
                }
            }
            trainedDataReady = true
        }
    }

    /** Decode bytes (JPEG/PNG/etc.), normalize EXIF, preprocess, OCR. Returns raw text or null. */
    fun scanImage(context: Context, bytes: ByteArray): String? {
        ensureTrainedData(context)
        val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            ?: throw IllegalArgumentException("Unable to decode image bytes")
        val oriented = applyExif(decoded, bytes)
        val processed = preprocess(oriented)
        return runTesseract(context, processed)
    }

    fun preprocess(bitmap: Bitmap): Bitmap { /* identical to FotoapparatCamera.preprocessImage */ }
    private fun runTesseract(context: Context, bitmap: Bitmap): String? { /* identical to scanMRZ */ }
    private fun applyExif(decoded: Bitmap, bytes: ByteArray): Bitmap { /* see EXIF section below */ }
}
```

Then in `FotoapparatCamera.kt`, replace the bodies of the private `preprocessImage` and `scanMRZ` with delegating calls to `MrzOcr.preprocess` / `MrzOcr.runTesseract` (made `internal`), or keep the private duplicates and tag for follow-up DRY. **Recommended:** delegate, so the live path reuses the same code. Verifier confirms live scanning still works (CONTEXT requires this).

**Cite — exact line ranges to touch:**
- Lines 31, 240–250 → move OCR core to `MrzOcr.runTesseract`.
- Lines 215–237 → move to `MrzOcr.preprocess`.
- Lines 58–62, 260–270 → move trained-data extraction to `MrzOcr.ensureTrainedData`. Keep the `init` block in `FotoapparatCamera` calling `MrzOcr.ensureTrainedData(context)` so live path startup is unchanged.

### iOS — Vision + SwiftyTesseract extraction

**Where it lives today** (`ios/Classes/MRZScannerView.swift`):
- SwiftyTesseract instance: line 15, `fileprivate let tesseract = SwiftyTesseract(language: .custom("ocrb"), bundle: ..., engineMode: .tesseractLstmCombined)`. Per-view, but the `TraineedDataBundle.bundle` is plugin-resource-bundled (see `ios/flutter_mrz_scanner_enhanced.podspec` line 16).
- `mrz(from cgImage: CGImage) -> String?` lines 111–120: preprocess + OCR.
- `preprocessImage(_ image: UIImage) -> UIImage` lines 124–142: grayscale via `CIColorControls(saturation:0)` + contrast bump (simulated threshold).
- Vision pipeline lives in `captureOutput(...)` lines 313–352: crops to `documentImage(from:)` (overlay-derived crop, lines 168–171), runs `VNDetectTextRectanglesRequest`, filters rectangles wider than 80% of the cropped image, takes the union, ensures height ≤ 40% of image, crops, calls `mrz(from:)`.
- For the static path the input is an arbitrary photo — there is no `videoPreviewLayer` to derive a crop from. Skip `documentImage` (it depends on `bounds` and `metadataOutputRectConverted` which require the live capture session). Run Vision on the **full** decoded `CGImage`. Keep the `>0.8 width` and `≤0.4 height` filters — they describe the MRZ band geometrically and are independent of the live preview.

**Recommended factoring:**

Create new file: `ios/Classes/MrzImageOcr.swift`

```swift
import UIKit
import Vision
import SwiftyTesseract

enum MrzImageOcrError: Error { case decodeFailed }

final class MrzImageOcr {
    static let shared = MrzImageOcr()

    private lazy var tesseract: SwiftyTesseract = {
        let bundle = Bundle(url: Bundle(for: MRZScannerView.self)
            .url(forResource: "TraineedDataBundle", withExtension: "bundle")!)!
        return SwiftyTesseract(language: .custom("ocrb"),
                               bundle: bundle,
                               engineMode: .tesseractLstmCombined)
    }()

    /// Returns raw recognized OCR text for the MRZ region, or nil if none found.
    func scanImage(data: Data) throws -> String? {
        guard let cgImage = Self.decode(data: data) else { throw MrzImageOcrError.decodeFailed }
        let mrzCrop = detectMrzRegion(in: cgImage) ?? cgImage  // fall back to full image
        return performOcr(on: mrzCrop)
    }

    private static func decode(data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // applies EXIF orientation:
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: true]
        return CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary)
            .flatMap { Self.applyExif($0, source: src) }
    }

    private func detectMrzRegion(in cgImage: CGImage) -> CGImage? {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let req = VNDetectTextRectanglesRequest()
        try? handler.perform([req])
        guard let results = req.results as? [VNTextObservation] else { return nil }
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        let t = CGAffineTransform.identity.scaledBy(x: w, y: -h).translatedBy(x: 0, y: -1)
        let rects = results.map { $0.boundingBox.applying(t) }.filter { $0.width > w * 0.8 }
        let union = rects.reduce(into: CGRect.null) { $0 = $0.union($1) }
        guard union.height <= h * 0.4, !union.isNull else { return nil }
        return cgImage.cropping(to: union)
    }

    private func performOcr(on cgImage: CGImage) -> String? {
        let pre = preprocess(UIImage(cgImage: cgImage))
        var out: String?
        tesseract.performOCR(on: pre) { out = $0 }
        return out
    }

    private func preprocess(_ image: UIImage) -> UIImage { /* identical to MRZScannerView.preprocessImage */ }
}
```

Then in `MRZScannerView.swift`, replace `mrz(from:)` and `preprocessImage(_:)` private members with calls to `MrzImageOcr.shared.performOcr(on:)` / `.preprocess(_:)`. **Recommended:** delegate to keep one source of truth. The `tesseract` instance moves from line 15 to `MrzImageOcr.shared.tesseract`; the live view holds a reference (or accesses the singleton).

**Cite — exact line ranges to touch:**
- Line 15 → move SwiftyTesseract init into `MrzImageOcr` lazy property.
- Lines 111–120 → delegate to `MrzImageOcr.shared.performOcr(on:)`.
- Lines 124–142 → move to `MrzImageOcr.preprocess`; keep a private wrapper in `MRZScannerView` if needed for `fileprivate` callsite at line 114.
- Lines 313–352 (Vision pipeline) → leave intact; the live path keeps overlay-driven crop. The static path uses a separate, simpler Vision call inside `MrzImageOcr.detectMrzRegion`.

## Plugin registration (global MethodChannel) — Android

**Current state** (`FlutterMrzScannerPlugin.kt`):
- `onAttachedToEngine` (lines 21–24) only registers the platform-view factory `mrzscanner`. No method channel at the plugin level.
- Per-view `MethodChannel("mrzscanner_$id")` is created in `MRZScannerView.<init>` (line 39).

**Where to add the global channel:** inside `FlutterMrzScannerPlugin.onAttachedToEngine`, after the existing `registerViewFactory` call. Keep a reference so we can null it out in `onDetachedFromEngine`.

```kotlin
class FlutterMrzScannerPlugin : FlutterPlugin {
    private var staticChannel: MethodChannel? = null
    private var appContext: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        binding.platformViewRegistry.registerViewFactory(
            "mrzscanner", MRZScannerFactory(binding)
        )
        staticChannel = MethodChannel(binding.binaryMessenger, "mrzscanner_static").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "scanImage" -> handleScanImage(call, result)
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        staticChannel?.setMethodCallHandler(null)
        staticChannel = null
        appContext = null
    }

    private fun handleScanImage(call: MethodCall, result: MethodChannel.Result) {
        val ctx = appContext ?: return result.error("NO_CONTEXT", "Plugin detached", null)
        val bytes = call.argument<ByteArray>("bytes")
            ?: return result.error("BAD_ARGS", "Missing bytes", null)
        val handler = android.os.Handler(android.os.Looper.getMainLooper())
        Thread {
            try {
                val text = MrzOcr.scanImage(ctx, bytes)
                handler.post { result.success(text) }
            } catch (e: Throwable) {
                handler.post { result.error("SCAN_FAILED", e.message, null) }
            }
        }.start()
    }
}
```

**Lazy vs eager init:** `MrzOcr.ensureTrainedData` is gated by a `@Volatile` flag and `synchronized`. First `scanImage` call pays the cost. **Recommendation: lazy.** Eager init in `onAttachedToEngine` would block engine attach on a disk write for a feature most users never invoke. Lazy is also safer if asset extraction throws — the error surfaces as a `PlatformException` on the actual call rather than silently failing at startup.

## Plugin registration (global MethodChannel) — iOS

**Current state:**
- `FlutterMrzScannerPlugin.m` (Obj-C shim) `+ registerWithRegistrar:` (lines 11–17) creates `FlutterMRZScannerFactory` and registers it as a view factory under `"mrzscanner"`. Stores the registrar in a static for later use.
- `SwiftFlutterMrzScannerPlugin.swift` defines `FlutterMRZScannerFactory` (lines 7–22) and `FlutterMRZScanner` (lines 24–110). Per-view `FlutterMethodChannel("mrzscanner_" + viewId)` is created in `create(...)` line 16–19.

**Where to add the global channel:** in the Obj-C `+registerWithRegistrar:` (preferred, since that's where `registrar.messenger` is already available) OR add a Swift class `MrzStaticChannel` and call into it from the Obj-C registrar. Recommended: keep Obj-C minimal, expose a Swift static method.

In `SwiftFlutterMrzScannerPlugin.swift` add:

```swift
@objc public class MrzStaticChannel: NSObject {
    @objc public static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "mrzscanner_static", binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            guard call.method == "scanImage" else { return result(FlutterMethodNotImplemented) }
            guard let args = call.arguments as? [String: Any],
                  let bytes = args["bytes"] as? FlutterStandardTypedData else {
                return result(FlutterError(code: "BAD_ARGS", message: "Missing bytes", details: nil))
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let text = try MrzImageOcr.shared.scanImage(data: bytes.data)
                    DispatchQueue.main.async { result(text) }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "SCAN_FAILED",
                                            message: error.localizedDescription, details: nil))
                    }
                }
            }
        }
    }
}
```

Then in `FlutterMrzScannerPlugin.m` `+registerWithRegistrar:` add (after the existing factory registration):

```objc
[MrzStaticChannel registerWithMessenger:registrar.messenger];
```

**Lazy vs eager init:** SwiftyTesseract `init` loads `traineddata` from a bundle resource (cheap; bundle is already mapped). `MrzImageOcr.shared` is a singleton with `lazy var tesseract`. **Recommendation: lazy** for symmetry with Android and to avoid loading SwiftyTesseract for users who never call `scanImage`.

## Image decoding & EXIF

### Android
- `BitmapFactory.decodeByteArray(bytes, 0, bytes.size)` handles JPEG/PNG/WebP/HEIF (HEIF on API 28+). Returns `null` on failure → throw `IllegalArgumentException` → maps to `PlatformException` (per CONTEXT error semantics).
- **EXIF concern:** decoded bitmap from `decodeByteArray` does NOT auto-rotate per EXIF. An arbitrary user-supplied JPEG (e.g. from `image_picker`) often carries `Orientation = 6` (camera held portrait). If we OCR a sideways MRZ band, Tesseract scores ~zero. The existing `takePhoto` path normalizes EXIF in `normalizeCapturedBitmap` (lines 106–119) and `applyExifOrientation` (lines 135–168) using `androidx.exifinterface.media.ExifInterface`.
- **Reuse target:** copy the body of `applyExifOrientation` (lines 135–168) and `readExifOrientation` (lines 121–133) into `MrzOcr.applyExif`. The existing live path's `rotationDegrees`-based branch (line 115) does not apply for static images — there's no camera rotation, only EXIF.
- **Decision:** YES, normalize EXIF for `scanImage`. Without this, `image_picker` photos will fail OCR most of the time. Caller-orientation-responsibility (mentioned in REQUIREMENTS out-of-scope as "Auto-rotation of the input image") refers to *content rotation* (e.g. user photographed the doc upside down). EXIF normalization is a different layer — it just respects the metadata the camera already wrote. Apply it.

### iOS
- Decode via `CGImageSourceCreateWithData(data as CFData, nil)` then `CGImageSourceCreateImageAtIndex(src, 0, ...)`. Returns `nil` on failure → throw → maps to `FlutterError`.
- **EXIF concern:** same as Android. By default `CGImageSourceCreateImageAtIndex` returns the raw pixel buffer without applying EXIF. The orientation tag is available via `CGImageSourceCopyPropertiesAtIndex(src, 0, nil)` → `kCGImagePropertyOrientation`.
- **Reuse target:** existing `MRZScannerView.createMatchingBackingDataWithImage(imageRef:orienation:)` (lines 412–496) already rotates a `CGImage` for any `UIImage.Orientation`. Reuse it in `MrzImageOcr.applyExif` by mapping `kCGImagePropertyOrientation` (1–8) → `UIImage.Orientation`. Make `createMatchingBackingDataWithImage` `internal` (or move to a shared `CGImage+Orientation.swift`) so both `MRZScannerView` and `MrzImageOcr` can call it.

## Threading model

### Android
- Live path uses `CoroutineScope(Dispatchers.IO + SupervisorJob())` (line 35) for OCR; result posted via `withContext(Dispatchers.Main)` (line 193).
- Static path: identical pattern. Use a plain `Thread {}` (shown above) or a shared `Executors.newSingleThreadExecutor()`. Either is fine; `Thread` keeps it dependency-free. Reply on `Looper.getMainLooper()` because `MethodChannel.Result` callbacks must run on the platform thread (= main thread).
- **Why not coroutines here:** the plugin class doesn't already hold a `CoroutineScope`. Adding one is fine but adds boilerplate (cancellation in `onDetachedFromEngine`). A throwaway `Thread` per call is simpler and fine for an interactive single-shot operation.

### iOS
- Live path uses `DispatchQueue.global(qos: .userInteractive)` for video frames (line 227).
- Static path: `DispatchQueue.global(qos: .userInitiated).async { ...; DispatchQueue.main.async { result(...) } }`. `userInitiated` (not `userInteractive`) because the user is waiting on a one-shot Future, not a 60fps stream.

### Memory
- **Android:** explicitly call `processed.recycle()` and `oriented.recycle()` after OCR completes inside `MrzOcr.scanImage` to avoid retaining ~10 MB native bitmap heap per call. Existing live path does NOT recycle — known minor leak; not new to this phase, but worth doing in the new helper.
- **iOS:** ARC handles `CGImage`/`UIImage`. Wrap the OCR inside `autoreleasepool { ... }` on the background queue to flush intermediate `UIImage` objects.

## Verification path (how to test in `example/`)

The example app currently only has `CameraPage` (live). It does NOT have an "upload an image" path. Wire one in:

1. Add `image_picker: ^1.0.0` to `example/pubspec.yaml` dependencies.
2. Create `example/lib/image_scan_page.dart`:
   ```dart
   import 'dart:typed_data';
   import 'package:flutter/material.dart';
   import 'package:flutter_mrz_scanner_enhanced/flutter_mrz_scanner_enhanced.dart';
   import 'package:image_picker/image_picker.dart';

   class ImageScanPage extends StatefulWidget { /* ... */ }
   class _ImageScanPageState extends State<ImageScanPage> {
     String? _result;
     Future<void> _pickAndScan() async {
       final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
       if (picked == null) return;
       final bytes = await picked.readAsBytes();
       final r = await MRZScanner.scanImage(bytes);
       setState(() => _result = r?.mrz ?? '(no MRZ)');
     }
     // ... button + Text(_result)
   }
   ```
3. Add a route from `main.dart` (e.g. a `Scaffold` with two buttons: "Live scan" / "Pick image").
4. **Test bitmap:** the user can take a passport photo on a real device with the existing camera page (`takePhoto` already saves PNGs to `tempDir`); reuse one of those for picking.

**Permission note:** `image_picker` on iOS needs `NSPhotoLibraryUsageDescription` in the example `Info.plist`. Plan must include this.

**No unit tests exist for the plugin.** The existing test infrastructure is just `flutter_test` from the example dev_dependencies. Adding a Dart-side unit test that asserts the static channel name and method args is the highest-ROI test (it doesn't need a device):

```dart
// test/static_channel_test.dart
test('scanImage uses mrzscanner_static channel', () async {
  const channel = MethodChannel('mrzscanner_static');
  final calls = <MethodCall>[];
  channel.setMockMethodCallHandler((c) async { calls.add(c); return null; });
  final r = await MRZScanner.scanImage(Uint8List.fromList([1,2,3]));
  expect(r, isNull);
  expect(calls.single.method, 'scanImage');
  expect(calls.single.arguments['bytes'], [1,2,3]);
});
```

## Pitfalls & mitigations

| # | Pitfall | Why it bites | Mitigation |
|---|---------|--------------|------------|
| 1 | `ocrb.traineddata` not extractable from non-camera context | Today the asset copy happens in `FotoapparatCamera.<init>`. If `scanImage` is called before any camera was ever instantiated, the cache file doesn't exist. | `MrzOcr.ensureTrainedData(context)` runs at the top of `scanImage`. Idempotent (skip if file exists). |
| 2 | `BitmapFactory.decodeByteArray` returns null on HEIC pre-API 28 | Some devices send HEIC from gallery | Throw `IllegalArgumentException` → `PlatformException("DECODE_FAILED")` per CONTEXT error semantics. Document JPEG/PNG as guaranteed; HEIC/WebP best-effort. |
| 3 | EXIF orientation ignored → sideways MRZ → empty OCR | Most camera photos arrive with `Orientation=6/8` | Apply EXIF on both platforms (see Image decoding section). |
| 4 | Bitmap memory leak (Android) | OCR'ing a 12MP photo without `recycle()` holds ~50 MB native heap until GC | Recycle intermediates in `MrzOcr.scanImage` `finally` block. |
| 5 | `TessBaseAPI.stop()` vs `recycle()` | `stop()` cancels the run; `recycle()` releases native memory. Existing code uses `stop()`. | Use `baseApi.recycle()` (or `end()`) in the new helper. Don't change live-path code (CONTEXT forbids behavior changes). |
| 6 | `MethodChannel` name collision across multiple Flutter engines | Add-to-app scenarios with multiple FlutterEngines each register the same channel name. The `BinaryMessenger` is per-engine so no actual collision occurs, but plugin cleanup must clear handlers in `onDetachedFromEngine`. | We do this in the Android `onDetachedFromEngine` shown above. iOS `FlutterPluginRegistrar` is per-engine; no manual cleanup required. |
| 7 | iOS `Bundle(for: MRZScannerView.self)` resolution | If we instantiate `MrzImageOcr` before `MRZScannerView` is referenced, the dynamic-class-bundle lookup may pick the app bundle. | Reference `MRZScannerView.self` (Swift class lookup) in the lazy init — same line as today. Verified working in current code (line 15). |
| 8 | Concurrent `scanImage` calls racing on shared `TessBaseAPI` | If we made Tesseract a singleton, parallel calls would corrupt state. | Current design: instantiate a fresh `TessBaseAPI` per call (matches today's `scanMRZ`). Thread-safe by construction. |
| 9 | `FlutterStandardTypedData` vs raw bytes | iOS receives `Uint8List` from Dart as `FlutterStandardTypedData`, not `Data` directly. | Cast `args["bytes"] as? FlutterStandardTypedData` then `.data`. Shown above. |
| 10 | Vision rectangle filter rejecting tightly-cropped MRZ images | If the caller pre-cropped to just the MRZ band, no rectangle will be wider than 80% of itself? Actually the band itself is wider than 80% of the crop, so the filter still passes. But the union may exceed 40% height. | Fall back to OCR'ing the full `cgImage` if `detectMrzRegion` returns nil (shown in `MrzImageOcr.scanImage` above: `?? cgImage`). |
| 11 | Live-path regression (CONTEXT-forbidden) | Refactor changes the live-frame OCR output | Verifier MUST re-run the example camera page on both platforms after the refactor and confirm scanning still works. Plan should include this as an explicit verification step. |
| 12 | Trained-data file extraction race | Two `scanImage` calls fired in parallel before the file exists could both write to the same path | `synchronized(this)` guard inside `ensureTrainedData` (shown above). |

## Open questions for the planner

1. **Should the live `FotoapparatCamera.scanMRZ` and `preprocessImage` be refactored to delegate to `MrzOcr`, or should we copy-paste and accept duplication?**
   - **Recommendation:** delegate. CONTEXT requires zero behavior change but does NOT require zero code change in the live path. One source of truth lowers regression risk. Verifier validates on real device.

2. **Should the EXIF-aware iOS rotation helper be moved out of `MRZScannerView` into a shared file, or left in place and called via an `internal` accessor?**
   - **Recommendation:** move to a new `ios/Classes/CGImage+Orientation.swift` file. Avoids a circular reference where `MrzImageOcr` depends on `MRZScannerView`.

3. **Where does the `_splitRecognized` helper live for the static path?**
   - Today it's a private method on `MRZController` (lines 110–116). The static `MRZScanner.scanImage` doesn't have a controller.
   - **Recommendation:** lift it to a top-level private function in `lib/src/mrz_scanner.dart` (e.g. `List<String> _splitRecognized(String)`) that both `MRZController._platformCallHandler` and `MRZScanner.scanImage` call. No public API change.

4. **Should the new global channel be registered even if the plugin is included but the static API is never called?**
   - **Yes.** Registration is cheap (one channel handler, no asset extraction). It must be registered eagerly in `onAttachedToEngine` so the *first* Dart call works. Only the trained-data extraction and Tesseract instantiation are lazy.

5. **Should the static channel name be versioned (e.g. `mrzscanner_static_v1`) to allow future signature changes?**
   - **Recommendation:** no, keep it simple (`mrzscanner_static`). Future changes can use new method names within the same channel.

## Sources

### Primary (HIGH confidence)
- Direct codebase inspection (file paths and line numbers cited inline above):
  - `lib/src/mrz_scanner.dart`
  - `android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/{FotoapparatCamera,FlutterMrzScannerPlugin}.kt`
  - `ios/Classes/{MRZScannerView,SwiftFlutterMrzScannerPlugin}.swift`, `FlutterMrzScannerPlugin.{h,m}`
  - `android/build.gradle`, `ios/flutter_mrz_scanner_enhanced.podspec`, `pubspec.yaml`, `example/lib/{main,camera_page}.dart`, `example/pubspec.yaml`
- `.planning/phases/01-image-based-mrz-scan/01-CONTEXT.md` (locked decisions)
- `.planning/{PROJECT,REQUIREMENTS,ROADMAP}.md`

### Secondary (knowledge — verified by codebase context)
- Flutter `MethodChannel` registration in `FlutterPlugin.onAttachedToEngine` is the standard non-platform-view entry point [CITED: docs.flutter.dev/packages-and-plugins/developing-packages].
- `androidx.exifinterface` `ExifInterface(InputStream)` reads tag values from JPEG/HEIF [CITED: developer.android.com/reference/androidx/exifinterface/media/ExifInterface].
- `CGImageSourceCopyPropertiesAtIndex` returns `kCGImagePropertyOrientation` in {1..8} (TIFF spec) [CITED: developer.apple.com/documentation/imageio/cgimagesource].
- `VNDetectTextRectanglesRequest` returns `VNTextObservation` with normalized bounding boxes [CITED: developer.apple.com/documentation/vision/vndetecttextrectanglesrequest].

## Metadata

**Confidence breakdown:**
- Native pipeline reuse plan: HIGH — verified by reading the exact source files cited.
- Plugin registration: HIGH — current registration code read directly; new code follows standard Flutter plugin patterns.
- EXIF / decoding: HIGH on Android (existing `applyExifOrientation` reused), MEDIUM on iOS (need to write the `kCGImagePropertyOrientation` → `UIImage.Orientation` mapping; reusing existing `createMatchingBackingDataWithImage`).
- Threading: HIGH.
- Pitfalls: HIGH for items rooted in the codebase (1, 4, 5, 11), MEDIUM for items extrapolated from Flutter/iOS general behavior (6, 7, 9).

**Research date:** 2026-05-07
**Valid until:** 2026-08-07 (90 days; codebase changes in `lib/src/mrz_scanner.dart` or the native plugin entrypoints may invalidate line numbers).
