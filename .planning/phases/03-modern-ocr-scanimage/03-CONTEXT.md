# Phase 3 Context: Modern OCR engines for `scanImage`

<domain>
The bundled `ocrb.traineddata` is a legacy Tesseract 3 model (~336 KB, no LSTM). One-shot still-image OCR therefore hits an accuracy ceiling that the live-camera path papers over by retrying Tesseract dozens of times per second until check digits validate.

This phase swaps the **still-image** OCR engine to a modern neural recognizer on each platform. The live camera path stays on Tesseract — it works fine there and switching it would mean app-size cost (Android) without much real-world benefit.

- **Phase 3a (executed):** iOS `MRZScanner.scanImage` uses Apple Vision `VNRecognizeTextRequest` instead of SwiftyTesseract. Free, ~0 MB cost, on-device, materially better on real-world camera photos.
- **Phase 3b (deliverable: PLAN.md only):** Android equivalent swap to MLKit on-device text recognition. Plan written; execution deferred until iOS is validated against the field.
</domain>

<canonical_refs>
- [.planning/REQUIREMENTS.md](../../REQUIREMENTS.md) — OCR-ENG-01, OCR-ENG-02
- [.planning/ROADMAP.md](../../ROADMAP.md) — Phase 3 goal
- [ios/Classes/MrzImageOcr.swift](../../../ios/Classes/MrzImageOcr.swift) — `scanImage(data:)` is the function being rewired
- [ios/Classes/MRZScannerView.swift](../../../ios/Classes/MRZScannerView.swift) — live path; calls `MrzImageOcr.shared.performOcr(on:)` at line 124. MUST be unchanged.
- [test/static_channel_test.dart](../../../test/static_channel_test.dart) — Phase 1 contract; channel name/method/args/return semantics must not change.
- Apple docs — `VNRecognizeTextRequest` (`recognitionLevel`, `recognitionLanguages`, `usesLanguageCorrection`, `customWords`, `topCandidates(_:)`).
</canonical_refs>

<code_context>
**Current iOS `scanImage(data:)` flow (lines 36-50):**
1. Decode bytes → `CGImage` via `CGImageSourceCreateWithData`.
2. Apply EXIF orientation.
3. `detectMrzRegion(in:)` — `VNDetectTextRectanglesRequest` to find candidate MRZ band; falls back to whole image.
4. `performOcr(on:)` — preprocess (grayscale + contrast), SwiftyTesseract OCR, return string.

**The live path** ([MRZScannerView.swift:123-124](../../../ios/Classes/MRZScannerView.swift)) calls `MrzImageOcr.shared.performOcr(on:)` directly. So `performOcr(on:)` is **shared between live and static**. We must NOT change it. Instead, change `scanImage(data:)` so it no longer calls `performOcr(on:)` — it uses Vision recognition directly and returns the joined MRZ text.

**Important Vision details:**
- `VNRecognizeTextRequest.recognitionLevel = .accurate` (slow but neural; `.fast` is the older detector).
- `usesLanguageCorrection = false` is **critical** — language correction would butcher passport numbers (e.g. correct `O` → `0`, but also might "correct" `0` → `O`). MRZ is not natural language.
- `recognitionLanguages = ["en-US"]` is fine; the OCR-B character set is a subset of Latin.
- For each `VNRecognizedTextObservation`, take `topCandidates(1).first?.string`. Filter to MRZ-shape candidates (uppercase A-Z, digits, `<`, length ≥ 30 ish — TD1 is 30, TD2 36, TD3 44).
- Optionally pass `customWords = ["<<", "<<<"]` to bias the recognizer toward MRZ filler character.
</code_context>

<decisions>

### iOS: which Vision API
**Decision:** Use `VNRecognizeTextRequest` with `recognitionLevel = .accurate`, `usesLanguageCorrection = false`, `recognitionLanguages = ["en-US"]`. No `customWords` initially (add only if real-world tests show systematic confusion).
**Why:** Best accuracy on real-world camera photos; matches how Apple itself reads passport MRZs in iOS. `.accurate` mode is slow (~hundreds of ms) but acceptable for a one-shot still-image path.
**Implication:** `scanImage(data:)` no longer calls `detectMrzRegion(...)` or `performOcr(on:)`. It runs Vision text recognition on the EXIF-corrected `CGImage` directly. Vision detects + recognizes in one pass.

### iOS: keep Tesseract for the live path
**Decision:** `MrzImageOcr.shared.performOcr(on:)` is unchanged. Live path keeps using SwiftyTesseract via that call. The legacy `detectMrzRegion(in:)` and `preprocess(_:)` helpers stay for the live path.
**Why:** Live path retries 30+ frames/sec; Tesseract is fine there. Vision per-frame would cost more, complicate threading, and might not even be faster end-to-end. No reason to change a working live path.
**Implication:** No diff in `MRZScannerView.swift`. The Phase 1 channel contract is preserved because the static channel path still calls `MrzImageOcr.shared.scanImage(data:)` — only its internals change.

### iOS: result filtering / shape
**Decision:** Collect `topCandidates(1).first?.string` from each observation, filter to lines that match `[A-Z0-9<]+` and length ≥ 30, sort by `boundingBox.minY` (top to bottom in image coords), join with `\n`. Return that string (or `nil` if no qualifying lines).
**Why:** Mirrors the existing return contract — Dart side already runs `_splitRecognized` + `MRZParser.tryParse` on the returned string. No Dart-side changes needed.
**Edge cases:** If Vision returns 0 lines, return `nil`. If it returns more than 4 MRZ-shaped lines (unusual), keep them all — the parser will discard non-MRZ lines.

### iOS: no SwiftyTesseract removal
**Decision:** Keep the `SwiftyTesseract` import + the `tesseract` lazy var in `MrzImageOcr`. The live path still uses it.
**Why:** Out of scope to remove a working dep that's still in use.

### Android: deferred to PLAN.md only
**Decision:** Write `03-ANDROID-PLAN.md` describing the MLKit swap. Don't execute it in this phase. Execution gated on iOS field validation.
**Why:** Two reasons. (1) Validate that "modern neural OCR fixes accuracy" actually pans out on real passports before committing to the Android engine swap (which adds ~2 MB and a Gradle dep). (2) Avoid PR scope sprawl.
**Plan must cover:** dep choice (`com.google.mlkit:text-recognition`), file diffs (`MrzOcr.kt`'s `scanImage` flow only — `runTesseract` for live path stays), threading (MLKit returns a `Task`; bridge to coroutine/sync), result filtering shape (same as iOS — line filter + join), gradle / proguard impact, app-size measurement, fallback / error handling.

</decisions>

<deferred>
- Android MLKit swap execution (this phase: plan only).
- Removing SwiftyTesseract dep entirely (would require also swapping the live path).
- A/B comparison harness that runs both engines on the same image and reports diff (would be useful, not blocking).
- `customWords` tuning for Vision (only if field testing shows specific systematic errors).
</deferred>

<open_questions>
None — decisions locked. Field validation against real passport photos is the only outstanding question and that's expected post-merge.
</open_questions>

---
*Last updated: 2026-05-07*
