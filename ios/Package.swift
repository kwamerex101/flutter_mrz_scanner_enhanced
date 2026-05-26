// swift-tools-version: 5.9
// Requires Flutter 3.22+ with `flutter config --enable-swift-package-manager`.
//
// ⚠️  arm64 SIMULATOR NOTE
// SwiftyTesseract 3.1.x ships no arm64-simulator slice in libtesseract.xcframework.
// CocoaPods consumers get the exclusion automatically via the podspec's
// `user_target_xcconfig`. SPM consumers must add it themselves in Xcode:
//   Target → Build Settings → Excluded Architectures [iphonesimulator] = arm64
// Physical-device (iphoneos) builds are unaffected.
import PackageDescription

let package = Package(
    name: "flutter_mrz_scanner_enhanced",
    platforms: [
        .iOS(.v13),
    ],
    products: [
        .library(name: "flutter_mrz_scanner_enhanced", targets: ["flutter_mrz_scanner_enhanced"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/SwiftyTesseract/SwiftyTesseract",
            .upToNextMinor(from: "3.1.3")
        ),
    ],
    targets: [
        .target(
            name: "flutter_mrz_scanner_enhanced",
            dependencies: [
                .product(name: "SwiftyTesseract", package: "SwiftyTesseract"),
            ],
            path: "Classes",
            resources: [
                // Preserve bundle structure so Tesseract can find tessdata/ocrb.traineddata
                // at runtime via Bundle.module (SPM) or Bundle(for:) (CocoaPods).
                .copy("../Assets/TraineedDataBundle.bundle"),
            ],
            publicHeadersPath: "."
        ),
    ]
)
