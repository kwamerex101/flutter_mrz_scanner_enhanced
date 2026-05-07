import UIKit
import Vision
import ImageIO
import SwiftyTesseract

enum MrzImageOcrError: Error { case decodeFailed }

/// Single source of truth for the Tesseract OCR pipeline on iOS. The live
/// `MRZScannerView` capture path delegates `mrz(from:)` and `preprocessImage(_:)`
/// to this class. The static `MRZScanner.scanImage` path (registered on the
/// global `mrzscanner_static` channel) calls `scanImage(data:)`.
final class MrzImageOcr {
    static let shared = MrzImageOcr()

    // Shared across live + static paths. CIContext is documented thread-safe
    // by Apple. Replaces a per-call CIContext(options: nil) allocation in
    // preprocess() (was at MrzImageOcr.swift:87 pre-Phase-2).
    static let sharedCIContext = CIContext(options: nil)

    // LOCKED — DO NOT change to a non-lazy initializer or rebuild per call.
    // The whole point of the shared singleton is one-time init for the
    // lifetime of the app. Live + static paths both share this instance;
    // serialization is enforced upstream (live: serial frame queue +
    // serial ocrQueue; static: SwiftFlutterMrzScannerPlugin global queue
    // + the one-call-at-a-time semantics of FlutterMethodChannel handlers).
    lazy var tesseract: SwiftyTesseract = {
        let bundle = Bundle(url: Bundle(for: MRZScannerView.self)
            .url(forResource: "TraineedDataBundle", withExtension: "bundle")!)!
        return SwiftyTesseract(language: .custom("ocrb"),
                               bundle: bundle,
                               engineMode: .tesseractLstmCombined)
    }()

    /// Decode bytes (JPEG/PNG/HEIC), apply EXIF orientation, detect MRZ region
    /// via Vision, OCR. Returns recognized text or nil.
    func scanImage(data: Data) throws -> String? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw MrzImageOcrError.decodeFailed
        }
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: true]
        guard let raw = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary) else {
            throw MrzImageOcrError.decodeFailed
        }

        return autoreleasepool { () -> String? in
            let oriented = Self.applyExif(raw, source: src)
            let mrzCrop = detectMrzRegion(in: oriented) ?? oriented
            return performOcr(on: mrzCrop)
        }
    }

    private static func applyExif(_ cgImage: CGImage, source: CGImageSource) -> CGImage {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = props[kCGImagePropertyOrientation] as? UInt32,
              raw != 1,
              let exif = CGImagePropertyOrientation(rawValue: raw) else {
            return cgImage
        }
        return applyExifOrientation(to: cgImage, exifOrientation: exif)
    }

    private func detectMrzRegion(in cgImage: CGImage) -> CGImage? {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let req = VNDetectTextRectanglesRequest()
        try? handler.perform([req])
        guard let results = req.results as? [VNTextObservation] else { return nil }
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let t = CGAffineTransform.identity.scaledBy(x: w, y: -h).translatedBy(x: 0, y: -1)
        let rects = results.map { $0.boundingBox.applying(t) }.filter { $0.width > w * 0.8 }
        let union = rects.reduce(into: CGRect.null) { $0 = $0.union($1) }
        guard !union.isNull, union.height <= h * 0.4 else { return nil }
        return cgImage.cropping(to: union)
    }

    /// Preprocess + OCR. Used by both the live `mrz(from:)` path and the static path.
    func performOcr(on cgImage: CGImage) -> String? {
        let originalImage = UIImage(cgImage: cgImage)
        let preprocessedImage = preprocess(originalImage)

        var recognizedString: String?
        tesseract.performOCR(on: preprocessedImage) { recognizedString = $0 }
        if let s = recognizedString, s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        return recognizedString
    }

    /// Grayscale + contrast (port of MRZScannerView.preprocessImage).
    func preprocess(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let ciImage = CIImage(cgImage: cgImage)
        let grayscale = ciImage.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        let threshold = grayscale.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: 4.0
        ])

        let context = Self.sharedCIContext
        if let outputCGImage = context.createCGImage(threshold, from: threshold.extent) {
            return UIImage(cgImage: outputCGImage)
        }
        return image
    }
}
