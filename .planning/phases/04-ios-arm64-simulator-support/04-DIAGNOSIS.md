DIAGNOSIS evidence captured:

1. pod install failed initially with two issues:
   a. Cocoapods encoding error (LANG not UTF-8). Workaround: prepend LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8.
   b. After encoding fix, CocoaPods reports:
      "CocoaPods could not find compatible versions for pod Flutter: required a higher minimum deployment target."

2. Flutter.xcframework (Flutter 3.41.9) requires MinimumOSVersion=13.0 for both device and simulator slices.

3. Current pins:
   - example/ios/Podfile:                  platform :ios, '12.0'
   - example/ios/Runner.xcodeproj (3x):    IPHONEOS_DEPLOYMENT_TARGET = 12.0
   - ios/flutter_mrz_scanner_enhanced.podspec: s.platform = :ios, '12.0'
   - ios/flutter_mrz_scanner.podspec (legacy/orphan): same

4. Conclusion:
   - Root cause of "build failure" on Apple Silicon simulators is NOT primarily SwiftyTesseract arm64
     exclusion. It is the iOS 12.0 deployment target being below Flutter 3.41.9's 13.0 floor.
     pod install never gets far enough to evaluate SwiftyTesseract arch slices.
   - The stale "EXCLUDED_ARCHS = i386" line in the plugin podspec is a separate latent issue worth
     cleaning up (no longer a valid simulator arch since Xcode 12).
   - SwiftyTesseract 3.1.3 arm64-simulator support cannot be confirmed without first resolving (4).
     Will re-check after deployment-target bump.

5. Fix sequence (revised from PLAN.md T2):
   - Bump deployment target to 13.0 across podspec + Podfile + Xcode project.
   - Drop the obsolete EXCLUDED_ARCHS=i386 from the plugin podspec.
   - Delete orphan ios/flutter_mrz_scanner.podspec.
   - Re-run pod install. If SwiftyTesseract then still fails on arm64-sim, escalate to Option B (bump constraint) or C (post_install).
