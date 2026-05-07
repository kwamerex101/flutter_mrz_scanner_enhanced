# Phase 3b — Android MLKit Results

**Status:** STUB — awaiting on-device verification (Task 5).

This document captures benchmark numbers and accuracy observations for the
Android MLKit `scanImage` swap. Tasks 1-4 (code) are complete; Task 5 (manual
on-device verification) is pending.

---

## Build / size impact

| Metric | Pre-MLKit (master) | Post-MLKit | Delta |
|---|---|---|---|
| `example/build/app/outputs/apk/debug/app-debug.apk` size | _TBD_ | _TBD_ | _TBD_ |
| `gradlew :app:assembleDebug` succeeds | _TBD_ | _TBD_ | — |

**Operator instructions:**
```bash
# Pre-MLKit baseline (checkout master or pre-Phase-3 SHA first):
cd example/android && ./gradlew :app:assembleDebug
ls -lh ../build/app/outputs/apk/debug/app-debug.apk

# Then return to this branch and re-build:
./gradlew clean :app:assembleDebug
ls -lh ../build/app/outputs/apk/debug/app-debug.apk
```

Budget: ≤ 3 MB delta. If exceeded, halt and reconsider.

---

## Benchmark (`integration_test/scan_image_bench_test.dart`)

| Metric | Pre-MLKit | Post-MLKit | Delta |
|---|---|---|---|
| p50 (ms) | _TBD_ | _TBD_ | _TBD_ |
| p99 (ms) | _TBD_ | _TBD_ | _TBD_ |
| Cold start (ms) | _TBD_ | _TBD_ | _TBD_ |

---

## Field test (10+ real passport photos)

| Condition | Pre-MLKit success rate | Post-MLKit success rate |
|---|---|---|
| Bright office light | _TBD_ | _TBD_ |
| Indoor warm light | _TBD_ | _TBD_ |
| Glare on laminate | _TBD_ | _TBD_ |
| Portrait orientation (EXIF=6) | _TBD_ | _TBD_ |
| Worn / scuffed passport | _TBD_ | _TBD_ |
| **Overall** | _TBD / N_ | _TBD / N_ |

---

## Live camera regression check

- [ ] `cd example && flutter run` — live preview opens
- [ ] Camera scans a passport via the live path; Tesseract returns a valid MRZ
- [ ] No new ANRs / crashes in `adb logcat`

---

*Last updated: 2026-05-07 (stub created during Tasks 1-4 execution).*
