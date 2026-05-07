import UIKit
import ImageIO

/// Rotates [imageRef] to match a UIImage.Orientation. Extracted from the live
/// `MRZScannerView.createMatchingBackingDataWithImage` so both the live capture
/// path and the static `MrzImageOcr` path share one EXIF-rotation implementation.
func createMatchingBackingDataWithImage(imageRef: CGImage?, orientation: UIImage.Orientation) -> CGImage? {
    // Skip the CGContext allocation + draw when no rotation/mirror is
    // needed. CGImage is immutable, so returning the original ref is safe.
    if orientation == .up {
        return imageRef
    }

    var orientedImage: CGImage?

    if let imageRef = imageRef {
        let originalWidth = imageRef.width
        let originalHeight = imageRef.height
        let bitsPerComponent = imageRef.bitsPerComponent
        let bytesPerRow = imageRef.bytesPerRow

        let bitmapInfo = imageRef.bitmapInfo

        guard let colorSpace = imageRef.colorSpace else {
            return nil
        }

        var degreesToRotate: Double
        var swapWidthHeight: Bool
        var mirrored: Bool
        switch orientation {
        case .up:
            degreesToRotate = 0.0; swapWidthHeight = false; mirrored = false
        case .upMirrored:
            degreesToRotate = 0.0; swapWidthHeight = false; mirrored = true
        case .right:
            degreesToRotate = 90.0; swapWidthHeight = true; mirrored = false
        case .rightMirrored:
            degreesToRotate = 90.0; swapWidthHeight = true; mirrored = true
        case .down:
            degreesToRotate = 180.0; swapWidthHeight = false; mirrored = false
        case .downMirrored:
            degreesToRotate = 180.0; swapWidthHeight = false; mirrored = true
        case .left:
            degreesToRotate = -90.0; swapWidthHeight = true; mirrored = false
        case .leftMirrored:
            degreesToRotate = -90.0; swapWidthHeight = true; mirrored = true
        @unknown default:
            degreesToRotate = 0.0; swapWidthHeight = false; mirrored = false
        }
        let radians = degreesToRotate * Double.pi / 180.0

        var width: Int
        var height: Int
        if swapWidthHeight {
            width = originalHeight
            height = originalWidth
        } else {
            width = originalWidth
            height = originalHeight
        }

        let contextRef = CGContext(data: nil, width: width, height: height, bitsPerComponent: bitsPerComponent, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo.rawValue)
        contextRef?.translateBy(x: CGFloat(width) / 2.0, y: CGFloat(height) / 2.0)
        if mirrored {
            contextRef?.scaleBy(x: -1.0, y: 1.0)
        }
        contextRef?.rotate(by: CGFloat(radians))
        if swapWidthHeight {
            contextRef?.translateBy(x: -CGFloat(height) / 2.0, y: -CGFloat(width) / 2.0)
        } else {
            contextRef?.translateBy(x: -CGFloat(width) / 2.0, y: -CGFloat(height) / 2.0)
        }
        contextRef?.draw(imageRef, in: CGRect(x: 0.0, y: 0.0, width: CGFloat(originalWidth), height: CGFloat(originalHeight)))
        orientedImage = contextRef?.makeImage()
    }

    return orientedImage
}

/// Maps a CGImagePropertyOrientation (1..8) to UIImage.Orientation and rotates accordingly.
func applyExifOrientation(to cgImage: CGImage, exifOrientation: CGImagePropertyOrientation) -> CGImage {
    let uiOrientation: UIImage.Orientation
    switch exifOrientation {
    case .up: uiOrientation = .up
    case .upMirrored: uiOrientation = .upMirrored
    case .down: uiOrientation = .down
    case .downMirrored: uiOrientation = .downMirrored
    case .left: uiOrientation = .left
    case .leftMirrored: uiOrientation = .leftMirrored
    case .right: uiOrientation = .right
    case .rightMirrored: uiOrientation = .rightMirrored
    @unknown default: uiOrientation = .up
    }
    return createMatchingBackingDataWithImage(imageRef: cgImage, orientation: uiOrientation) ?? cgImage
}
