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

    /// Decode bytes (JPEG/PNG/HEIC), apply EXIF orientation, OCR with
    /// Apple Vision's neural text recognizer. Returns recognized MRZ text
    /// (one MRZ line per `\n`-separated entry) or nil.
    ///
    /// NOTE: this path used to call SwiftyTesseract via `performOcr(on:)`.
    /// As of Phase 3 the static still-image path uses Vision instead — the
    /// bundled `ocrb.traineddata` is a legacy Tesseract 3 model with no LSTM
    /// and hits an accuracy ceiling on one-shot images. The live camera path
    /// (MRZScannerView.captureOutput) keeps using Tesseract via
    /// `performOcr(on:)`; that helper is intentionally NOT modified.
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
            return Self.recognizeMrzLines(in: oriented)
        }
    }

    /// Run Vision text recognition on the full image and stitch MRZ-shaped
    /// candidate lines together (top-to-bottom). Returns nil when no
    /// MRZ-shaped line is found.
    ///
    /// Vision detects + recognizes in one pass — no separate
    /// `VNDetectTextRectanglesRequest` step needed (that helper is left
    /// in place for the live Tesseract path).
    private static func recognizeMrzLines(in cgImage: CGImage) -> String? {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Critical for MRZ — language correction would mangle passport
        // numbers (e.g. swap 0/O, 1/I) since MRZ is not natural language.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        // Bias toward MRZ filler. Harmless if not present in the image.
        request.customWords = ["<<", "<<<"]

        do { try handler.perform([request]) } catch { return nil }
        guard let observations = request.results as? [VNRecognizedTextObservation],
              !observations.isEmpty else { return nil }

        // Each observation = one detected line. Sort top-to-bottom in image
        // coordinates (Vision uses bottom-left origin, so larger minY = higher).
        let sorted = observations.sorted { $0.boundingBox.minY > $1.boundingBox.minY }

        let mrzLines: [String] = sorted.compactMap { obs in
            guard let raw = obs.topCandidates(1).first?.string else { return nil }
            // Normalize like the Dart side does (`<` aliases) before
            // length-checking so quirky recognizer outputs (`«`, spaces) still
            // pass the gate.
            let normalized = raw
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "«", with: "<")
                .uppercased()
            // MRZ alphabet is A-Z, 0-9, < — anything else disqualifies.
            // Shortest valid MRZ line is TD1 at 30 chars; allow a small
            // tolerance for OCR slop on edge characters.
            guard normalized.count >= 28,
                  normalized.allSatisfy({ ($0.isLetter && $0.isASCII) || $0.isNumber || $0 == "<" }) else {
                return nil
            }
            return normalized
        }

        guard !mrzLines.isEmpty else { return nil }
        return mrzLines.joined(separator: "\n")
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

    /// Preprocess + OCR. Used by the live `mrz(from:)` path only —
    /// the static `scanImage(data:)` path uses Vision (see Phase 3).
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
