# Phase 4 — iOS arm64 simulator support (executable plan)

**Goal:** Make `flutter_mrz_scanner_enhanced` build, link, and launch on Apple Silicon iOS simulators (arm64 iphonesimulator slice) without regressing the physical-device path. Pure build/tooling fix — no product behavior changes.

**Status:** Ready to execute.

---

## Constraints / what must NOT change

- Live camera path (`MRZScannerView` + SwiftyTesseract) keeps working on physical iPhones.
- `MRZScanner.scanImage` (Apple Vision on iOS) keeps working on physical iPhones.
- Android build is untouched.
- iOS deployment target stays `12.0` unless a SwiftyTesseract version bump forces a higher minimum (and even then, document and confirm before bumping).
- OCR behavior (Tesseract trained data, Vision, MLKit) is untouched.

## Authoritative context

Read these before touching code:
- `.planning/phases/04-ios-arm64-simulator-support/04-CONTEXT.md` — locked decisions.
- `ios/flutter_mrz_scanner_enhanced.podspec` — current podspec; arm64-sim fix lives here.
- `ios/flutter_mrz_scanner.podspec` — orphan legacy podspec; delete.
- `example/ios/Podfile` — last-resort patch site (post_install).
- `CLAUDE.md` — `pod install` workflow under "Common commands".

## Task list

### T1 — Diagnose the actual failure on this Mac
Reproduce the build failure first; do not patch blind.

1. `cd example && flutter pub get`
2. `cd example/ios && pod install` (capture full output)
3. `cd .. && xcrun simctl list devices available | grep -i "iPhone"` — pick an arm64 simulator (any modern iPhone sim on Apple Silicon).
4. `flutter run -d <simulator-id-or-name>` — capture full build log.

Record in `04-DIAGNOSIS.md`:
- Exact pod versions resolved (especially `SwiftyTesseract` actual version).
- Whether `pod install` warns about arch exclusion.
- Whether the linker error mentions `arm64` slice missing in a specific framework.
- `lipo -info $(find example/ios/Pods -name "SwiftyTesseract*.framework" -o -name "SwiftyTesseract*.a" 2>/dev/null | head -1)` — confirm which slices SwiftyTesseract ships.

Commit `04-DIAGNOSIS.md` so the fix is justified by evidence.

### T2 — Apply minimal fix (ranked, take first that resolves)

**Option A — Drop obsolete podspec workaround (try first).**
If T1 shows SwiftyTesseract itself ships arm64-sim, the failure is just the stale `EXCLUDED_ARCHS = 'i386'` line. `i386` is not a valid simulator arch since Xcode 12, and pairing it with implicit `arm64` exclusion in nested specs sometimes leaks. Remove the line in `ios/flutter_mrz_scanner_enhanced.podspec`:

```diff
-  # Flutter.framework does not contain a i386 slice.
-  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
+  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
```

**Option B — Bump SwiftyTesseract** (only if T1 shows SwiftyTesseract 3.1.3 lacks arm64-sim).
Update the dependency constraint and verify API compatibility:

```diff
-  s.dependency 'SwiftyTesseract', '~> 3.1.3'
+  s.dependency 'SwiftyTesseract', '~> 4.0'
```

If a 4.x bump is required:
- Audit `ios/Classes/MRZScannerView.swift` and `ios/Classes/MrzImageOcr.swift` (if still uses SwiftyTesseract) for breaking API changes.
- Note: Phase 3 already swapped `scanImage` to Vision on iOS, so SwiftyTesseract is now only used by the live camera path in `MRZScannerView.swift`. Smaller blast radius.
- Document in the commit body why the bump was required.
- Re-verify deployment target compatibility with the new SwiftyTesseract version.

**Option C — Post-install escape hatch in example Podfile** (last resort).
If neither A nor B is feasible (e.g., SwiftyTesseract truly has no arm64-sim and 4.x is incompatible), add to `example/ios/Podfile` post_install:

```ruby
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    target.build_configurations.each do |config|
      config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= ['$(inherited)', 'PERMISSION_CAMERA=1']
      # Only exclude arm64 for simulator on Intel Macs:
      config.build_settings['EXCLUDED_ARCHS[sdk=iphonesimulator*]'] = 'arm64' if `uname -m`.strip == 'x86_64'
    end
  end
end
```

Document the limitation in README (Apple Silicon dev requires arm64 sim; this would force Rosetta) and call it out as a known issue rather than the fix.

### T3 — Delete the orphan legacy podspec
`ios/flutter_mrz_scanner.podspec` is unreferenced (pubspec.yaml only mentions `flutter_mrz_scanner_enhanced`). Delete it. Single commit so it's easy to revert if some hidden tooling broke.

```bash
git rm ios/flutter_mrz_scanner.podspec
```

### T4 — Re-run pod install + simulator build
1. `rm -rf example/ios/Pods example/ios/Podfile.lock`
2. `cd example/ios && pod install`
3. `cd .. && flutter run -d <arm64 simulator>` — expect to reach the camera permission prompt (the simulator has no camera so live scan won't function past that, which is fine — we're proving the binary builds and links).

### T5 — Regression check on physical device path
Build (don't necessarily run) for a real device target to prove no regression:
```bash
cd example && flutter build ios --no-codesign --debug
```
Must succeed.

### T6 — Update CLAUDE.md note (optional, only if Option B or C was used)
If we bumped SwiftyTesseract or added a post_install workaround, append a one-line note under "Things to know when changing code" so future Claude sessions see the new build constraint. Skip if Option A worked — nothing to document.

(Reminder: CLAUDE.md is flagged `--skip-worktree` locally; commits to it must be done via `git update-index --no-skip-worktree CLAUDE.md` first, then committed, then re-flagged.)

### T7 — flutter analyze sanity check
```bash
flutter analyze
```
Must be clean.

## Acceptance criteria

1. `flutter run -d <arm64 simulator>` from `example/` reaches the camera permission prompt (or the camera-unavailable runtime message) on Apple Silicon. Build + link + launch succeed.
2. `flutter build ios --no-codesign --debug` from `example/` succeeds — physical-device path intact.
3. `flutter analyze` is clean.
4. `pod install` in `example/ios` produces no arch warnings tied to the plugin.
5. `ios/flutter_mrz_scanner.podspec` no longer exists.
6. `04-DIAGNOSIS.md` records the actual root cause; the committed fix references it.

## Out of scope

- Adding CI that builds for arm64 simulator (separate phase).
- Bumping `iOS deployment target` above 12.0 unless forced.
- Touching Android.
- Any OCR behavior change.

## Rollback

Each task is its own commit. If anything regresses physical-device builds:
1. `git revert` the task commit(s).
2. Investigate via `04-DIAGNOSIS.md` evidence.
3. Drop to the next-ranked option in T2.
