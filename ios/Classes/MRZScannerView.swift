import UIKit
import AVFoundation
import SwiftyTesseract
import AudioToolbox
import Vision

public protocol MRZScannerViewDelegate: AnyObject {
    func onParse(_ parsed: String?)
    func onError(_ error: String?)
    func onPhoto(_ data: Data?)
}

public class MRZScannerView: UIView {
    // OCR is now centralized in MrzImageOcr.shared (used by both live and static paths).
    fileprivate let captureSession = AVCaptureSession()
    fileprivate let videoOutput = AVCaptureVideoDataOutput()
    fileprivate let photoOutput = AVCapturePhotoOutput()
    fileprivate let videoPreviewLayer = AVCaptureVideoPreviewLayer()
    fileprivate var isScanningPaused = false
    fileprivate var observer: NSKeyValueObservation?
    // Drop-while-busy throttle: while OCR is in flight on `ocrQueue`, new
    // frames are dropped at captureOutput entry — preview queue stays free.
    private let ocrSemaphore = DispatchSemaphore(value: 1)
    private let ocrQueue = DispatchQueue(label: "mrz_ocr_queue", qos: .userInitiated)
    // Reused across frames; safe because the upstream serial frame queue
    // (video_frames_queue) and this serial ocrQueue together guarantee
    // non-concurrent perform() calls on this VNRequest. The static path
    // (MrzImageOcr.scanImage) uses Apple Vision text recognition entirely
    // separately — see Phase 3 — so there is no shared VNRequest to worry about.
    private lazy var textDetectionRequest: VNDetectTextRectanglesRequest = {
        let r = VNDetectTextRectanglesRequest()
        r.reportCharacterBoxes = false
        return r
    }()
    @objc public dynamic var isScanning = false
    public weak var delegate: MRZScannerViewDelegate?
    private var photoData: Data?
    fileprivate var shouldCrop: Bool = false
    fileprivate var isFrontCam: Bool = false

    fileprivate var interfaceOrientation: UIInterfaceOrientation {
        return UIApplication.shared.statusBarOrientation
    }
    
    // MARK: - Added Flashlight Control (matching Android torch())
    public func flashlightOn() {
        guard let device = AVCaptureDevice.default(for: .video),
              device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = .on
            device.unlockForConfiguration()
        } catch {
            delegate?.onError("Flashlight error: \(error.localizedDescription)")
        }
    }
    
    public func flashlightOff() {
        guard let device = AVCaptureDevice.default(for: .video),
              device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = .off
            device.unlockForConfiguration()
        } catch {
            delegate?.onError("Flashlight error: \(error.localizedDescription)")
        }
    }
    
    // MARK: Initializers
    override public init(frame: CGRect) {
        super.init(frame: frame)
        // EDIT: Uncommented initialize call if needed.
        // initialize()
    }
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        // EDIT: Uncommented initialize call if needed.
        // initialize()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: Overriden methods
    override public func prepareForInterfaceBuilder() {
        setViewStyle()
    }
    
    override public func layoutSubviews() {
        super.layoutSubviews()
        adjustVideoPreviewLayerFrame()
    }
    
    // MARK: Scanning
    public func startScanning(_ isFrontCam: Bool) {
        self.isFrontCam = isFrontCam
        if captureSession.inputs.isEmpty {
            self.initialize()
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.startRunning()
            DispatchQueue.main.async { [weak self] in self?.adjustVideoPreviewLayerFrame() }
        }
    }
    
    public func stopScanning() {
        captureSession.stopRunning()
    }
    
    // EDIT: Updated takePhoto to more closely match Android's behavior.
    // Instead of saving to a file, we send the image data (cropped or full) via the delegate.
    public func takePhoto(shouldCrop: Bool) {
        self.shouldCrop = shouldCrop
        photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }
    
    // MARK: MRZ
    // EDIT: Updated mrz(from:) to perform pre‑processing (grayscale & thresholding) before OCR.
    fileprivate func mrz(from cgImage: CGImage) -> String? {
        return MrzImageOcr.shared.performOcr(on: cgImage)
    }

    // MARK: Preprocessing
    fileprivate func preprocessImage(_ image: UIImage) -> UIImage {
        return MrzImageOcr.shared.preprocess(image)
    }
    
    // MARK: Document Image from Photo cropping
    // EDIT: calculateCutoutRect updated to use same document ratio as Android (86/55 ≈ 1.5636)
fileprivate func cutoutRect(for cgImage: CGImage) -> CGRect {
    let imageWidth = CGFloat(cgImage.width)
    let imageHeight = CGFloat(cgImage.height)
    // Call the updated calculateCutoutRect function with cropToMRZ set to true.
    // Here, we're using the view's bounds as the reference size.
    let rect = videoPreviewLayer.metadataOutputRectConverted(fromLayerRect: calculateCutoutRect(for: bounds.size, cropToMRZ: false))
    let videoOrientation = videoPreviewLayer.connection!.videoOrientation

    if videoOrientation == .portrait || videoOrientation == .portraitUpsideDown {
        return CGRect(x: (rect.minY * imageWidth),
                      y: (rect.minX * imageHeight),
                      width: (rect.height * imageWidth),
                      height: (rect.width * imageHeight))
    } else {
        return CGRect(x: (rect.minX * imageWidth),
                      y: (rect.minY * imageHeight),
                      width: (rect.width * imageWidth),
                      height: (rect.height * imageHeight))
    }
}

    
    fileprivate func documentImage(from cgImage: CGImage) -> CGImage {
        let croppingRect = cutoutRect(for: cgImage)
        return cgImage.cropping(to: croppingRect) ?? cgImage
    }
    
    // MARK: UIApplication Observers
    @objc fileprivate func appWillEnterForeground() {
        if isScanningPaused {
            isScanningPaused = false
            startScanning(self.isFrontCam)
        }
    }
    
    @objc fileprivate func appDidEnterBackground() {
        if isScanning {
            isScanningPaused = true
            stopScanning()
        }
    }
    
    // MARK: Init methods
    fileprivate func initialize() {
        setViewStyle()
        initCaptureSession()
        addAppObservers()
    }
    
    fileprivate func setViewStyle() {
        backgroundColor = .black
    }
    
    fileprivate func initCaptureSession() {
        captureSession.sessionPreset = .hd1920x1080
        
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: self.isFrontCam ? .front : .back) else {
            delegate?.onError("Camera not accessible")
            print("Camera not accessible")
            return
        }
        
        guard let deviceInput = try? AVCaptureDeviceInput(device: camera) else {
            delegate?.onError("Capture input could not be initialized")
            print("Capture input could not be initialized")
            return
        }
        
        observer = captureSession.observe(\.isRunning, options: [.new]) { [unowned self] (model, change) in
            // Ensure UI updates on main thread.
            DispatchQueue.main.async { [weak self] in self?.isScanning = change.newValue! }
        }
        
        if captureSession.canAddInput(deviceInput) &&
            captureSession.canAddOutput(videoOutput) &&
            captureSession.canAddOutput(photoOutput) {
            
            captureSession.addInput(deviceInput)
            captureSession.addOutput(videoOutput)
            captureSession.addOutput(photoOutput)
            
            videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "video_frames_queue", qos: .userInteractive, attributes: [], autoreleaseFrequency: .workItem))
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as [String : Any]
            videoOutput.connection(with: .video)!.videoOrientation = AVCaptureVideoOrientation(orientation: interfaceOrientation)
            
            videoPreviewLayer.session = captureSession
            videoPreviewLayer.videoGravity = .resizeAspectFill
            
            layer.insertSublayer(videoPreviewLayer, at: 0)
        }
        else {
            delegate?.onError("Input & Output could not be added to the session")
        }
    }
    
    fileprivate func addAppObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    
    // MARK: Misc
    fileprivate func adjustVideoPreviewLayerFrame() {
        videoOutput.connection(with: .video)?.videoOrientation = AVCaptureVideoOrientation(orientation: interfaceOrientation)
        videoPreviewLayer.connection?.videoOrientation = AVCaptureVideoOrientation(orientation: interfaceOrientation)
        videoPreviewLayer.frame = bounds
    }
    
// New function: calculateCutoutRect(for:cropToMRZ:)
// This mirrors the Kotlin function by using the document ratio (86/55)
// and optionally cropping only the bottom 35% (MRZ area) if cropToMRZ is true.
fileprivate func calculateCutoutRect(for imageSize: CGSize, cropToMRZ: Bool) -> CGRect {
    let documentFrameRatio = CGFloat(86.0 / 55.0) // same ratio as Flutter overlay
    
    // Calculate document frame dimensions based on the image size.
    let width: CGFloat
    let height: CGFloat
    if imageSize.height > imageSize.width {
        width = imageSize.width * 0.9  // 90% of available width
        height = width / documentFrameRatio
    } else {
        height = imageSize.height * 0.75  // 75% of available height
        width = height * documentFrameRatio
    }
    
    // Center the document region within the image.
    let leftOffset = (imageSize.width - width) / 2.0
    let topOffset = (imageSize.height - height) / 2.0
    
    if !cropToMRZ {
        // Normal cropping: Expand the region with a margin (10% extra on each side)
        let marginPercentage = CGFloat(0.1)
        let marginX = width * marginPercentage
        let marginY = height * marginPercentage
        
        let newLeft = max(0, leftOffset - marginX)
        let newTop = max(0, topOffset - marginY)
        var newWidth = width * (1 + 2 * marginPercentage)
        var newHeight = height * (1 + 2 * marginPercentage)
        
        if newLeft + newWidth > imageSize.width {
            newWidth = imageSize.width - newLeft
        }
        if newTop + newHeight > imageSize.height {
            newHeight = imageSize.height - newTop
        }
        return CGRect(x: newLeft, y: newTop, width: newWidth, height: newHeight)
    } else {
        // Crop to MRZ area only: 35% of the document frame height at the bottom.
        let mrzHeight = height * 0.35
        let mrzLeft = leftOffset
        let mrzTop = topOffset + height - mrzHeight
        let mrzWidth = width
        
        let cropLeft = max(0, mrzLeft)
        let cropTop = max(0, mrzTop)
        let cropWidth = (cropLeft + mrzWidth > imageSize.width) ? imageSize.width - cropLeft : mrzWidth
        let cropHeight = (cropTop + mrzHeight > imageSize.height) ? imageSize.height - cropTop : mrzHeight
        
        return CGRect(x: cropLeft, y: cropTop, width: cropWidth, height: cropHeight)
    }
}

}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension MRZScannerView: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Drop-while-busy: skip this frame if a previous OCR is still running
        // on `ocrQueue`. Preserves preview FPS by keeping the frame queue free.
        guard ocrSemaphore.wait(timeout: .now()) == .success else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let cgImage = pixelBuffer.cgImage else {
            ocrSemaphore.signal()
            return
        }

        // EDIT: Crop the full frame to the document area (cheap, on frame queue).
        let documentImage = self.documentImage(from: cgImage)
        // Move heavy Vision + Tesseract work off the frame queue so the
        // capture pipeline isn't blocked by OCR latency.
        ocrQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.ocrSemaphore.signal() }

            let imageRequestHandler = VNImageRequestHandler(cgImage: documentImage, options: [:])
            do {
                try imageRequestHandler.perform([self.textDetectionRequest])
            } catch {
                return
            }
            guard let results = self.textDetectionRequest.results as? [VNTextObservation] else { return }

            let imageWidth = CGFloat(documentImage.width)
            let imageHeight = CGFloat(documentImage.height)
            let transform = CGAffineTransform.identity.scaledBy(x: imageWidth, y: -imageHeight).translatedBy(x: 0, y: -1)
            let mrzTextRectangles = results.map({ $0.boundingBox.applying(transform) }).filter({ $0.width > (imageWidth * 0.8) })
            let mrzRegionRect = mrzTextRectangles.reduce(into: CGRect.null, { $0 = $0.union($1) })

            // Only process if the region is not too tall (mirror Android check).
            guard mrzRegionRect.height <= (imageHeight * 0.4) else { return }

            if let mrzTextImage = documentImage.cropping(to: mrzRegionRect),
               let mrzResult = self.mrz(from: mrzTextImage) {
                DispatchQueue.main.async { self.delegate?.onParse(mrzResult) }
            }
        }
    }
}

extension MRZScannerView: AVCapturePhotoCaptureDelegate {
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            print("Error capturing photo: \(error)")
        } else {
            photoData = photo.fileDataRepresentation()
            // EDIT: Use the device's orientation instead of a fixed one.
            let currentOrientation = self.interfaceOrientation
            let uiOrientation: UIImage.Orientation = {
                switch currentOrientation {
                case .portrait: return .right
                case .portraitUpsideDown: return .left
                case .landscapeLeft: return .up
                case .landscapeRight: return .down
                default: return .right
                }
            }()
            
            // EDIT: Adjust the rotation using the updated orientation.
            let cgImage = photo.cgImageRepresentation()!
            let rotated = createMatchingBackingDataWithImage(imageRef: cgImage, orientation: uiOrientation)
            let resized = resize(rotated!)
            if self.shouldCrop {
                // Crop the image to the document area.
                let document = self.documentImage(from: resized ?? rotated!)
                
                // Save to temporary storage
                if let pngData = document.png {
                    saveImageToTemporaryStorage(imageData: pngData)
                }
                
                delegate?.onPhoto(document.png)
            } else {
                let img = resized ?? rotated!
                
                // Save to temporary storage
                if let pngData = img.png {
                    saveImageToTemporaryStorage(imageData: pngData)
                }
                
                delegate?.onPhoto(img.png)
            }
        }
    }
    
    private func saveImageToTemporaryStorage(imageData: Data) {
        do {
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = "mrz_image_\(Int(Date().timeIntervalSince1970)).png"
            let fileURL = tempDir.appendingPathComponent(fileName)
            try imageData.write(to: fileURL)
            print("Image saved to temporary storage: \(fileURL.path)")
        } catch {
            print("Error saving image to temporary storage: \(error)")
        }
    }
    
    func resize(_ image: CGImage) -> CGImage? {
        var ratio: Float = 0.0
        let imageWidth = Float(image.width)
        let imageHeight = Float(image.height)
        let maxWidth: Float = 720.0
        let maxHeight: Float = 1280.0

        // Skip resize when already within target bounds — avoid an
        // unnecessary CGContext allocation + per-pixel draw.
        if imageWidth <= maxWidth && imageHeight <= maxHeight {
            return image
        }

        // Get ratio (landscape or portrait)
        if imageWidth > imageHeight {
            ratio = maxWidth / imageWidth
        } else {
            ratio = maxHeight / imageHeight
        }
        
        if ratio > 1 {
            ratio = 1
        }
        
        let width = imageWidth * ratio
        let height = imageHeight * ratio
        
        guard let colorSpace = image.colorSpace else { return nil }
        guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: image.bitsPerComponent, bytesPerRow: image.bytesPerRow, space: colorSpace, bitmapInfo: image.bitmapInfo.rawValue) else { return nil }
        
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: Int(width), height: Int(height)))
        
        return context.makeImage()
    }
}

extension AVCaptureVideoOrientation {
    internal init(orientation: UIInterfaceOrientation) {
        switch orientation {
        case .portrait:
            self = .portrait
        case .portraitUpsideDown:
            self = .portraitUpsideDown
        case .landscapeLeft:
            self = .landscapeLeft
        case .landscapeRight:
            self = .landscapeRight
        default:
            self = .portrait
        }
    }
}

extension CVImageBuffer {
    var cgImage: CGImage? {
        CVPixelBufferLockBaseAddress(self, .readOnly)
        
        let baseAddress = CVPixelBufferGetBaseAddress(self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(self)
        let (width, height) = (CVPixelBufferGetWidth(self), CVPixelBufferGetHeight(self))
        let bitmapInfo = CGBitmapInfo(rawValue: (CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
        let context = CGContext(data: baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo.rawValue)
        
        guard let cgImage = context?.makeImage() else {
            return nil
        }
        
        CVPixelBufferUnlockBaseAddress(self, .readOnly)
        
        return cgImage
    }
}

extension CGImage {
    var png: Data? {
        guard let mutableData = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(mutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, self, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }
}
