# Phase 4 Context: iOS arm64 simulator support

Date: 2026-05-12

## Domain
Build/tooling fix on the iOS side. Make `flutter_mrz_scanner_enhanced` and its `example/` host app build, link, and run on Apple Silicon iOS simulators (arm64 iphonesimulator slice). Today it works on physical devices but breaks on M1/M2/M3 simulators. No product feature work — pure infrastructure.

## Skip-discussion rationale
Per `discuss-phase.md` "skip assessment" rule: no meaningful gray areas. Single technical objective, mechanical fix, success measured by `flutter run -d <arm64 simulator>` succeeding.

## Locked decisions

### D1. Fix lives in the plugin, not consumer apps
The plugin's `ios/flutter_mrz_scanner_enhanced.podspec` is the authoritative place. Consumers should not have to patch their own Podfiles to use the plugin on Apple Silicon.

### D2. Investigation order before patching
Determine the real cause before applying a fix. Two suspects:
1. **The plugin's own podspec** — `EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'` is a stale Xcode-11-era workaround; modern Xcode no longer needs `i386` excluded since it isn't a valid simulator arch anymore. This line is benign on Intel but is often paired with the `arm64` exclusion that breaks Apple Silicon. Re-check it.
2. **SwiftyTesseract 3.1.3** — old dependency. May ship a `.framework` without an `arm64` simulator slice (it predates the xcframework-with-Apple-Silicon-sim era). If SwiftyTesseract itself lacks the arm64-sim slice, no consumer-side fix can work.

Sequence: (a) try `pod install` + `flutter run` on an arm64 simulator with the current podspec; (b) inspect linker errors / arch slices of the resolved SwiftyTesseract binary; (c) pick the minimal fix that actually addresses the failure.

### D3. Preferred remedies (ranked, pick first that resolves)
1. **Remove obsolete `EXCLUDED_ARCHS = i386`** from the plugin's podspec if and only if SwiftyTesseract already supports arm64 simulator.
2. **Upgrade `SwiftyTesseract` constraint** to a version that ships arm64 simulator support (e.g. `~> 4.0` if available and ABI-compatible).
3. **Targeted exclusion**: add `'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'arm64'` to the example app's Podfile post_install (documented escape hatch). **Last resort** — degrades Apple Silicon dev experience to Rosetta and is contagious to consumers.

### D4. Physical-device path must not regress
The live camera + scanImage flows already work on real iPhones. Any change must keep that intact. Verification step explicitly re-runs on a physical device after the simulator fix.

### D5. Cleanup: orphan podspec
`ios/flutter_mrz_scanner.podspec` (legacy name, `VALID_ARCHS = x86_64`) is not referenced by `pubspec.yaml` (only `flutter_mrz_scanner_enhanced.podspec` is). It is dead weight and a footgun if someone trips over it. Delete it as part of this phase.

### D6. Out of scope
- Android build changes.
- Bumping iOS deployment target above 12.0 unless required by the SwiftyTesseract upgrade.
- Touching OCR behavior (Tesseract trained data, MLKit, Vision) — Phase 3 already covered that.
- Adding CI for arm64 simulator builds (own phase if needed).

## Canonical refs

- `ios/flutter_mrz_scanner_enhanced.podspec` — the active podspec (arm64 sim fix lives here).
- `ios/flutter_mrz_scanner.podspec` — orphan legacy podspec to delete.
- `example/ios/Podfile` — consumer-side Podfile; post_install hook is the last-resort patch site.
- `CLAUDE.md` — notes iOS deployment target 12.0 and "After bumping iOS deps in the example: `cd example/ios && pod install`".
- `.planning/ROADMAP.md` — Phase 4 entry.

## Code context (reusable)
None. This is a build-config phase; nothing to share with prior phases.

## Verification gate
1. `cd example && flutter pub get`
2. `cd example/ios && pod install` succeeds without arch warnings.
3. `flutter run -d <arm64 iphone simulator>` from `example/` builds, links, and reaches the camera permission prompt on a fresh boot of an arm64 simulator on this Mac (darwin 25.4.0, Apple Silicon).
4. `flutter run -d <physical iPhone>` (or at least a build for device) still succeeds — no regression.
5. `flutter analyze` clean.
