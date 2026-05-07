# Android MLKit swap — executable plan

**Status:** PLAN ONLY (not yet executed). Execution gated on iOS Vision swap (Phase 3a) showing measurable accuracy improvement against real passports.

**Goal:** Mirror the iOS Phase 3a swap on Android. `MRZScanner.scanImage(bytes)` on Android stops using the legacy `ocrb.traineddata` Tesseract pipeline and switches to **Google ML Kit on-device text recognition**. The live camera path (`FotoapparatCamera`) is unchanged — it keeps using Tesseract via `MrzOcr.runTesseractWith` because that path retries dozens of frames per second and Tesseract is fine there.

**Why MLKit (and not eng.traineddata from tessdata_best):** General-English LSTM is not OCR-B-specialized; switching to it is a gamble that may not actually improve accuracy. MLKit's text recognition is a modern neural model trained on diverse real-world text and consistently beats legacy Tesseract on photos taken with phone cameras. Confirmed industry-standard for this kind of work.

---

## Constraints / what must NOT change

- The Phase 1 channel contract: channel `mrzscanner_static`, method `scanImage`, args `{'bytes': bytes}`, return type `String?`. Asserted by `test/static_channel_test.dart` (3 cases). Tests must still pass.
- The live camera path (`FotoapparatCamera.processFrame` → `MrzOcr.runTesseractWith`) is byte-for-byte unchanged externally. No Tesseract removal, no `MrzOcr` deletion — `MrzOcr` keeps the live-path entry points; only the static `scanImage` flow is rewired.
- No regression in `mrz_parser` — Dart still receives a `\n`-separated string of MRZ candidate lines and validates with `MRZParser.tryParse`.
- App-size budget: ~2-3 MB acceptable (MLKit on-device text-recognition v2). Reject text-recognition v1 (older, larger).

## Dependencies

Add to `android/build.gradle` (the plugin's, not the app's):

```gradle
dependencies {
    // …existing…
    implementation 'com.google.mlkit:text-recognition:16.0.1'
}
```

(Verify the latest `16.0.x` at the time of execution. Pin a specific version, do not use `+`.)

No app-side changes for consumers — MLKit is bundled into the plugin AAR. Consumers do **not** need to add a separate dependency or model download flow because the on-device Latin model ships with the library.

**Manifest:** MLKit auto-registers a meta-data entry telling Play Store to download/keep the OCR model. No additional manifest changes required.

**ProGuard / R8:** MLKit is R8-friendly out of the box. No keep rules needed for our usage.

---

## Files modified (final list)

| File | Change |
|---|---|
| [android/build.gradle](../../../android/build.gradle) | Add `mlkit:text-recognition` dep |
| [android/src/main/kotlin/.../MrzOcr.kt](../../../android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/MrzOcr.kt) | New `scanImageWithMlkit(context, bytes): String?`. Replace the body of `scanImage(...)` to call it. Tesseract code paths (`acquireSharedBaseApi`, `runTesseractWith`, `runTesseract`, `preprocess`, EXIF helpers) stay because the live path uses them. |
| [android/src/main/kotlin/.../FlutterMrzScannerPlugin.kt](../../../android/src/main/kotlin/io/github/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced/FlutterMrzScannerPlugin.kt) | `handleScanImage` is unchanged externally — it still calls `MrzOcr.scanImage(ctx, bytes)`. Internally only the result delivery may change because MLKit's API is async (see threading task below). |
| `android/src/main/AndroidManifest.xml` | None expected. If a future MLKit version requires a `<meta-data>` for app-size optimization (e.g. `com.google.mlkit.vision.DEPENDENCIES`), add it here. |

No deletions. No new Kotlin files (the MLKit code lives inside `MrzOcr` to keep one entry point for the channel handler).

---

## Tasks

### Task 1 — Add MLKit dep + smoke build

**Files:** `android/build.gradle`

**Diff intent:** add `implementation 'com.google.mlkit:text-recognition:16.0.1'` (pin version after running `./gradlew dependencies` to confirm latest stable).

**Acceptance:**
- `cd example/android && ./gradlew :app:assembleDebug` succeeds.
- APK size delta in MB recorded in commit message.

**Commit:** `chore(03b): add ML Kit text-recognition dep`

---

### Task 2 — Implement `scanImageWithMlkit`

**File:** `android/src/main/kotlin/.../MrzOcr.kt`

**Diff intent:**

Add (do NOT remove existing methods; live path still needs them):

```kotlin
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

// Lazy single recognizer for the lifetime of the plugin (MLKit recommends reuse).
@Volatile
private var mlkitRecognizer: com.google.mlkit.vision.text.TextRecognizer? = null
private val mlkitLock = Any()

private fun getMlkitRecognizer(): com.google.mlkit.vision.text.TextRecognizer {
    mlkitRecognizer?.let { return it }
    synchronized(mlkitLock) {
        mlkitRecognizer?.let { return it }
        val r = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
        mlkitRecognizer = r
        return r
    }
}

/**
 * Decode bytes (JPEG/PNG/etc.), apply EXIF orientation, run MLKit text
 * recognition. Returns MRZ-shaped lines joined with `\n`, or null.
 */
private fun scanImageWithMlkit(context: Context, bytes: ByteArray): String? {
    val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        ?: throw IllegalArgumentException("Unable to decode image bytes")
    val oriented = applyExif(decoded, bytes)
    return try {
        val input = InputImage.fromBitmap(oriented, 0)
        val recognizer = getMlkitRecognizer()
        // MLKit's process() returns a Task — bridge to sync via a latch.
        // The channel handler thread is already a worker (see
        // FlutterMrzScannerPlugin.handleScanImage), so blocking here is fine.
        val latch = CountDownLatch(1)
        var resultText: String? = null
        var failure: Exception? = null
        recognizer.process(input)
            .addOnSuccessListener { text ->
                resultText = filterMrzLines(text.text)
                latch.countDown()
            }
            .addOnFailureListener { e ->
                failure = e
                latch.countDown()
            }
        if (!latch.await(15, TimeUnit.SECONDS)) {
            throw RuntimeException("MLKit text recognition timed out")
        }
        if (failure != null) throw failure!!
        resultText
    } finally {
        if (oriented !== decoded) oriented.recycle()
        decoded.recycle()
    }
}

/** Filter MLKit's recognized text down to MRZ-shaped lines. */
private fun filterMrzLines(raw: String): String? {
    val mrzLines = raw.split('\n').mapNotNull { line ->
        val normalized = line
            .replace(" ", "")
            .replace("«", "<")
            .uppercase()
        // MRZ shortest line is TD1 at 30 chars; allow small tolerance for OCR slop.
        if (normalized.length >= 28 &&
            normalized.all { it.isLetterOrDigit() || it == '<' } &&
            normalized.any { it == '<' || it.isDigit() }) {
            normalized
        } else null
    }
    return if (mrzLines.isEmpty()) null else mrzLines.joined("\n")
}
```

(Use `joinToString("\n")` — `joined` was a typo in the snippet above.)

Then **rewire** `MrzOcr.scanImage` to delegate:

```kotlin
fun scanImage(context: Context, bytes: ByteArray): String? {
    return scanImageWithMlkit(context, bytes)
}
```

The Tesseract-based scanImage body becomes dead code internal to the static path **but** all the helper methods (`ensureTrainedData`, `acquireSharedBaseApi`, `runTesseractWith`, `preprocess`, EXIF helpers) stay because the live camera path (`FotoapparatCamera`) still uses them.

If `applyExif` is `private`, promote it to `internal` so the new MLKit path can call it (or keep it private and inline the call — preference: keep `private` and call from within `MrzOcr`).

**Threading note:** `FlutterMrzScannerPlugin.handleScanImage` already runs on a `Thread { … }.start()` worker, so `latch.await(...)` does not block the Flutter platform thread. Delivery back to Dart is via `result.success(...)` posted to the main looper inside the existing handler — **do not change that part**.

**Acceptance:**
- `flutter test test/static_channel_test.dart` — 3/3 pass (channel contract held).
- `cd example && flutter pub get && flutter run` on a real Android device — picking a passport image returns a non-null `MRZFullResult` with correct fields.
- `cd example && flutter run` — live camera scan still parses correctly (Tesseract path unchanged).

**Commit:** `feat(03b): swap Android scanImage to ML Kit text recognition`

---

### Task 3 — Recognizer cleanup on plugin teardown

**File:** `android/src/main/kotlin/.../FlutterMrzScannerPlugin.kt`

**Diff intent:** in `onDetachedFromEngine`, call:

```kotlin
MrzOcr.shutdownMlkit()
```

And in `MrzOcr.kt` add:

```kotlin
fun shutdownMlkit() {
    synchronized(mlkitLock) {
        mlkitRecognizer?.close()
        mlkitRecognizer = null
    }
}
```

Why: MLKit recognizers hold native resources. Calling `.close()` is recommended by Google when the engine no longer needs them. For a plugin, plugin detach is the natural lifetime boundary.

**Acceptance:** open/close 5 example app sessions; `adb logcat | grep -i mlkit` shows no leaked-instance warnings.

**Commit:** `feat(03b): release ML Kit recognizer on plugin detach`

---

### Task 4 — Update unit test (negative-path additions)

**File:** `test/static_channel_test.dart`

**Diff intent:** existing 3 assertions still hold (channel name, parse-failure → null, valid TD3 → MRZFullResult). Add one more case: when the channel returns a multi-line string with both MRZ-shaped and non-MRZ lines, the Dart side correctly forwards to `mrz_parser` and only valid MRZ parses through. This guards against MLKit returning richer noise than the old Tesseract pipeline did.

**Acceptance:** 4/4 pass.

**Commit:** `test(03b): cover multi-line OCR output forwarding`

---

### Task 5 — Manual on-device verification + benchmark refresh

Mirror Phase 2's `02-BASELINE.md` workflow:
1. Run the existing `integration_test/scan_image_bench_test.dart` against the **pre-MLKit** build (this branch's HEAD before Task 1). Record p50 / p99 / cold latency.
2. Run it against the post-MLKit build. Record again.
3. Field-test against 10+ real passport photos covering:
   - Bright office light
   - Indoor warm light
   - Glare on the laminate
   - Phone camera in portrait mode (Orientation=6)
   - Worn / scuffed passports
   Record success rate before vs after.
4. Write `03-ANDROID-RESULTS.md` capturing the numbers; update STATE.md.

**Commit (after results land):** `docs(03b): record Android MLKit benchmark results`

---

## Pitfalls / risks

| Risk | Mitigation |
|---|---|
| MLKit downloads model on first run if not bundled. Older versions (<16.0.0) needed `Play Services` and on-demand download. Latest bundles the Latin model. | Pin `16.0.1`+ which bundles. Verify with `apkanalyzer files cat example/build/app/outputs/apk/debug/app-debug.apk` — model file should be present. |
| MLKit's text output is whole-image text grouped into blocks, not raw lines. The exact structure differs from Tesseract output. | `filterMrzLines` splits on newlines and filters by MRZ-shape — same as iOS Vision path. Already covered. |
| MLKit may recognize MRZ as `«` or other lookalikes. | Pre-normalize `«` → `<` (shown in `filterMrzLines`). |
| Latch `await` blocks the worker thread. If MLKit fails silently, the call hangs. | 15-second timeout with explicit exception. |
| App-size blow-up. | Recorded in Task 1 commit message. If > 3 MB, halt and reconsider. |
| Live path regression. | We only edit the static `scanImage` flow + add new helpers. The live path's `runTesseractWith` is untouched. Phase 1 test catches API contract regressions. Manual live-camera test in Task 2 catches behavioral regressions. |
| Older Android versions. | MLKit text-recognition v2 supports API 21+. The plugin's `minSdkVersion` should already be ≥ 21 (Flutter requirement). |
| `InputImage.fromBitmap(_, 0)` rotation arg — is it relative to oriented or raw image? | We pre-rotate via `applyExif` and pass `0`. Documented in MLKit reference: `0` means "image is already in its display orientation". |

---

## Rollback

If MLKit causes issues post-merge:
1. Revert the commits from Task 1 (the gradle dep) and Task 2 (the MrzOcr rewire).
2. `MrzOcr.scanImage` body reverts to its current Tesseract path — already proven and unit-test-covered.
3. The live path is untouched throughout, so rollback is contained.

Single-commit rollback is feasible because Tasks 1 & 2 together form a discrete unit.

---

## Done criteria for the phase

- [ ] All tasks committed.
- [ ] `flutter test test/static_channel_test.dart` — 4/4 pass (after Task 4).
- [ ] APK size delta documented; ≤ 3 MB.
- [ ] Manual passport scan rate improvement documented in `03-ANDROID-RESULTS.md`.
- [ ] Live camera scan still works on a real device.
- [ ] No new analyzer warnings in changed files.
- [ ] `MRZScanner.scanImage` API contract unchanged (channel name, method, args, return type).
