package io.github.elmehdaouiahmed.flutter_mrz_scanner_enhanced

import kotlinx.coroutines.*
import android.content.Context
import android.graphics.*
import androidx.exifinterface.media.ExifInterface
import androidx.annotation.NonNull
import androidx.core.content.ContextCompat
import com.googlecode.tesseract.android.TessBaseAPI
import io.flutter.plugin.common.MethodChannel
import io.fotoapparat.Fotoapparat
import io.fotoapparat.configuration.CameraConfiguration
import io.fotoapparat.configuration.UpdateConfiguration
import io.fotoapparat.preview.Frame
import io.fotoapparat.selector.off
import io.fotoapparat.selector.torch
import io.fotoapparat.view.CameraView
import java.io.ByteArrayOutputStream
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import io.fotoapparat.selector.*
import io.fotoapparat.parameter.*
import io.fotoapparat.selector.manualJpegQuality
import android.util.Log

class FotoapparatCamera constructor(
    val context: Context,
    var messenger: MethodChannel
) {
    private var mainExecutor = ContextCompat.getMainExecutor(context)
    private val job = SupervisorJob()
    private val scope = CoroutineScope(Dispatchers.IO + job)

    // Per-session TessBaseAPI for the live camera frame path. Lazily inited
    // on first OCR call, recycled in [dispose]. SEPARATE from the static
    // path's MrzOcr.acquireSharedBaseApi(...) — see CONTEXT.md.
    private var tessApi: TessBaseAPI? = null
    private val tessLock = Any()
    // Drop-while-busy throttle: while OCR is in flight on `scope`, new
    // frames are dropped at processFrame entry — no preprocessing, no
    // bitmap allocation, no coroutine launch.
    private val ocrInFlight = java.util.concurrent.atomic.AtomicBoolean(false)

    val cameraView = CameraView(context)

    val configuration = CameraConfiguration(
        frameProcessor = this::processFrame,
        focusMode = firstAvailable(
            continuousFocusPicture(),
            autoFocus(),
            fixed()
        ),
        pictureResolution = highestResolution(),
        previewResolution = highestResolution(),
        previewFpsRange = highestFps(),
        jpegQuality = manualJpegQuality(90)
    )

    val fotoapparat = Fotoapparat(
        context = context,
        view = cameraView,
        cameraConfiguration = configuration
    )

    init {
        MrzOcr.ensureTrainedData(context)
    }

    fun flashlightOn() {
        fotoapparat.updateConfiguration(UpdateConfiguration(flashMode = torch()))
    }

    fun flashlightOff() {
        fotoapparat.updateConfiguration(UpdateConfiguration(flashMode = off()))
    }

    fun takePhoto(@NonNull result: MethodChannel.Result, crop: Boolean) {
        val photoResult = fotoapparat.autoFocus().takePicture()
        photoResult.toPendingResult().whenAvailable { photo ->
            if (photo == null) {
                mainExecutor.execute {
                    result.error("CAPTURE_ERROR", "Failed to capture photo", null)
                }
                return@whenAvailable
            }

            try {
                val normalizedBitmap = normalizeCapturedBitmap(photo.encodedImage, photo.rotationDegrees)
                val outputBitmap = if (crop) {
                    calculateCutoutRectCardSize(normalizedBitmap, false)
                } else {
                    normalizedBitmap
                }

                val stream = ByteArrayOutputStream()
                outputBitmap.compress(Bitmap.CompressFormat.JPEG, 100, stream)
                val outputBytes = stream.toByteArray()

                mainExecutor.execute {
                    result.success(outputBytes)
                }
            } catch (e: Exception) {
                Log.e("FotoapparatCamera", "Failed to process captured photo: ${e.message}", e)
                mainExecutor.execute {
                    result.error("PHOTO_PROCESSING_ERROR", "Failed to process photo", null)
                }
            }
        }
    }

    private fun normalizeCapturedBitmap(imageBytes: ByteArray, rotationDegrees: Int): Bitmap {
        val decodedBitmap = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
            ?: throw IllegalStateException("Unable to decode captured image bytes")

        val exifOrientation = readExifOrientation(imageBytes)

        return if (exifOrientation == ExifInterface.ORIENTATION_NORMAL ||
            exifOrientation == ExifInterface.ORIENTATION_UNDEFINED
        ) {
            rotateBitmap(decodedBitmap, rotationAngle(rotationDegrees))
        } else {
            applyExifOrientation(decodedBitmap, exifOrientation)
        }
    }

    private fun readExifOrientation(imageBytes: ByteArray): Int {
        return try {
            ByteArrayInputStream(imageBytes).use { input ->
                val exifInterface = ExifInterface(input)
                exifInterface.getAttributeInt(
                    ExifInterface.TAG_ORIENTATION,
                    ExifInterface.ORIENTATION_NORMAL
                )
            }
        } catch (_: Exception) {
            ExifInterface.ORIENTATION_UNDEFINED
        }
    }

    private fun applyExifOrientation(source: Bitmap, orientation: Int): Bitmap {
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> {
                matrix.setScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_180 -> {
                matrix.setRotate(180f)
            }
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> {
                matrix.setRotate(180f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.setRotate(90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_90 -> {
                matrix.setRotate(90f)
            }
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.setRotate(-90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_270 -> {
                matrix.setRotate(-90f)
            }
            else -> {
                return source
            }
        }

        return Bitmap.createBitmap(source, 0, 0, source.width, source.height, matrix, true)
    }
    
    private fun rotationAngle(rotation: Int): Int {
        return when (rotation) {
            90 -> -90
            270 -> 90
            180 -> 180
            else -> rotation
        }
    }

    // Process the full frame: apply pre‑processing and OCR without cropping.
    private fun processFrame(frame: Frame) {
        // Drop frames while a previous OCR is still running. Gate FIRST so
        // that we also skip the per-pixel preprocessing cost when busy.
        if (!ocrInFlight.compareAndSet(false, true)) return
        val processedBitmap: Bitmap = try {
            // Direct NV21 Y-plane → binarized + rotated bitmap. Already
            // grayscale + thresholded — preprocessImage() is redundant on
            // the live path now.
            val bitmap = nv21ToBinaryBitmap(frame)
            val cropped = calculateCutoutRectCardSize(bitmap, true)
            // calculateCutoutRectCardSize may return the source itself if
            // crop matches the full bitmap; only recycle when distinct.
            if (cropped !== bitmap) {
                try { bitmap.recycle() } catch (_: Throwable) {}
            }
            cropped
        } catch (t: Throwable) {
            ocrInFlight.set(false)
            throw t
        }
        scope.launch {
            try {
                val mrzText = scanMRZ(processedBitmap)
                val fixedMrz = extractMRZ(mrzText)
                withContext(Dispatchers.Main) {
                    messenger.invokeMethod("onParsed", fixedMrz)
                }
            } finally {
                // Recycle the per-frame bitmap (Tesseract.setImage copies
                // pixels into Pix; we own the Bitmap from here).
                try { processedBitmap.recycle() } catch (_: Throwable) {}
                ocrInFlight.set(false)
            }
        }
    }

    /**
     * Legacy fallback: YuvImage → JPEG → Bitmap roundtrip. Retained so
     * [nv21ToBinaryBitmap] can fall back if a device delivers an unexpected
     * NV21 buffer size (stride/padding).
     */
    private fun getImageJpeg(frame: Frame): Bitmap {
        val out = ByteArrayOutputStream()
        val yuvImage = YuvImage(frame.image, ImageFormat.NV21, frame.size.width, frame.size.height, null)
        yuvImage.compressToJpeg(Rect(0, 0, frame.size.width, frame.size.height), 100, out)
        val imageBytes = out.toByteArray()
        val image = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
        return rotateBitmap(image, -frame.rotation)
    }

    /**
     * Convert NV21 frame's Y plane directly to a binarized ARGB_8888 Bitmap
     * (BLACK / WHITE), applying the same threshold (128) as MrzOcr.preprocess
     * AND rotating to upright via index math. Single allocation, single
     * pass — eliminates the YUV → JPEG → Bitmap roundtrip plus the
     * grayscale + threshold passes.
     *
     * Falls back to [getImageJpeg] if the buffer is smaller than expected
     * (defensive guard against stride/padding surprises).
     */
    private fun nv21ToBinaryBitmap(frame: Frame, threshold: Int = 128): Bitmap {
        val w = frame.size.width
        val h = frame.size.height
        val y = frame.image
        if (y.size < w * h) {
            Log.w(
                "FotoapparatCamera",
                "Unexpected NV21 buffer size ${y.size} (expected >= ${w * h}); falling back to JPEG path"
            )
            return getImageJpeg(frame)
        }
        val rot = frame.rotation
        val outW: Int
        val outH: Int
        if (rot == 90 || rot == 270) {
            outW = h
            outH = w
        } else {
            outW = w
            outH = h
        }
        val pixels = IntArray(outW * outH)
        val black = Color.BLACK
        val white = Color.WHITE
        for (j in 0 until outH) {
            for (i in 0 until outW) {
                val sx: Int
                val sy: Int
                when (rot) {
                    90 -> { sx = j;          sy = w - 1 - i }
                    180 -> { sx = w - 1 - i; sy = h - 1 - j }
                    270 -> { sx = h - 1 - j; sy = i }
                    else -> { sx = i;        sy = j }
                }
                val luma = y[sy * w + sx].toInt() and 0xFF
                pixels[j * outW + i] = if (luma < threshold) black else white
            }
        }
        val bmp = Bitmap.createBitmap(outW, outH, Bitmap.Config.ARGB_8888)
        bmp.setPixels(pixels, 0, outW, 0, 0, outW, outH)
        return bmp
    }

    private fun rotateBitmap(source: Bitmap, angle: Int): Bitmap {
        val matrix = Matrix()
        matrix.postRotate(angle.toFloat())
        return Bitmap.createBitmap(source, 0, 0, source.width, source.height, matrix, true)
    }

    // Preprocess the image by converting it to grayscale and applying a simple threshold.
    private fun preprocessImage(bitmap: Bitmap): Bitmap {
        return MrzOcr.preprocess(bitmap)
    }

    private fun ensureTessApi(): TessBaseAPI {
        tessApi?.let { return it }
        synchronized(tessLock) {
            tessApi?.let { return it }
            MrzOcr.ensureTrainedData(context)
            val api = TessBaseAPI()
            api.init(context.cacheDir.absolutePath, "ocrb")
            api.setVariable(
                "tessedit_char_whitelist",
                "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789<"
            )
            api.pageSegMode = TessBaseAPI.PageSegMode.PSM_SINGLE_BLOCK
            tessApi = api
            return api
        }
    }

    // LIVE-PATH EXIF NOTE:
    // Live frames are routed through MrzOcr.runTesseractWith, NOT
    // MrzOcr.scanImage. Therefore MrzOcr.applyExif() is NEVER called on
    // live frames — `frame.rotation` (handled in nv21ToBinaryBitmap) is the
    // only orientation source the live path needs. Static-path scanImage
    // continues to apply EXIF for image_picker / takePhoto inputs.
    // Do not "factor out" by routing live frames through scanImage(bytes).
    // Run OCR using Tesseract on the provided bitmap.
    private fun scanMRZ(bitmap: Bitmap): String {
        val api = ensureTessApi()
        // Live frame queue is serial; no external lock needed.
        return MrzOcr.runTesseractWith(api, bitmap) ?: ""
    }

    private fun extractMRZ(input: String): String {
        val lines = input.split("\n")
        val mrzLength = lines.last().length
        val mrzLines = lines.takeLastWhile { it.length == mrzLength }
        return mrzLines.joinToString("\n")
    }

/**
 * Calculates a crop region based on the same document size used in your Flutter overlay.
 * It uses the aspect ratio 86:55 and the same width/height percentages,
 * then expands the region by a given margin to allow for misalignment.
 */
    private fun calculateCutoutRect(bitmap: Bitmap, cropToMRZ: Boolean): Bitmap {
    // Use the same document ratio as in your Flutter overlay.
    val documentFrameRatio = 86.0 / 55.0

    val width: Double
    val height: Double

    // Calculate document frame dimensions based on bitmap size.
    if (bitmap.height > bitmap.width) {
        width = bitmap.width * 0.9  // 90% of available width
        height = width / documentFrameRatio
    } else {
        height = bitmap.height * 0.75  // 75% of available height
        width = height * documentFrameRatio
    }

    // Center the document region within the image.
    val leftOffset = (bitmap.width - width) / 2.0
    val topOffset = (bitmap.height - height) / 2.0

    return if (!cropToMRZ) {
        // Normal cropping: Expand the region with a margin (10% extra on each side)
        val marginPercentage = 0.1
        val marginX = width * marginPercentage
        val marginY = height * marginPercentage

        val newLeft = (leftOffset - marginX).coerceAtLeast(0.0)
        val newTop = (topOffset - marginY).coerceAtLeast(0.0)
        var newWidth = width * (1 + 2 * marginPercentage)
        var newHeight = height * (1 + 2 * marginPercentage)

        if (newLeft + newWidth > bitmap.width) {
            newWidth = bitmap.width - newLeft
        }
        if (newTop + newHeight > bitmap.height) {
            newHeight = bitmap.height - newTop
        }

        Bitmap.createBitmap(bitmap, newLeft.toInt(), newTop.toInt(), newWidth.toInt(), newHeight.toInt())
    } else {
        // Crop to MRZ area only: 35% of the document frame height at the bottom.
        val mrzHeight = height * 0.35
        val mrzLeft = leftOffset
        val mrzTop = topOffset + height - mrzHeight
        val mrzWidth = width

        val cropLeft = mrzLeft.coerceAtLeast(0.0)
        val cropTop = mrzTop.coerceAtLeast(0.0)
        val cropWidth = if (cropLeft + mrzWidth > bitmap.width) bitmap.width - cropLeft else mrzWidth
        val cropHeight = if (cropTop + mrzHeight > bitmap.height) bitmap.height - cropTop else mrzHeight

        Bitmap.createBitmap(bitmap, cropLeft.toInt(), cropTop.toInt(), cropWidth.toInt(), cropHeight.toInt())
    }
    }

    private fun calculateCutoutRectCardSize(bitmap: Bitmap, cropToMRZ: Boolean): Bitmap {
        val documentFrameRatio = 1.42 // Passport's size (ISO/IEC 7810 ID-3) is 125mm × 88mm
        val width: Double
        val height: Double
    
        if (bitmap.height > bitmap.width) {
            width = bitmap.width * 0.9 // Fill 90% of the width
            height = width / documentFrameRatio
        } else {
            height = bitmap.height * 0.75 // Fill 75% of the height
            width = height * documentFrameRatio
        }
    
        val mrzZoneOffset = if (cropToMRZ) height * 0.6 else 0.0
        val topOffset = ((bitmap.height - height) / 2 + mrzZoneOffset).coerceAtLeast(0.0)
        val leftOffset = ((bitmap.width - width) / 2).coerceAtLeast(0.0)
    
        val cropWidth = width.coerceAtMost(bitmap.width - leftOffset)
        val cropHeight = (height - mrzZoneOffset).coerceAtMost(bitmap.height - topOffset)
    
        // Validate crop dimensions
        if (cropWidth <= 0 || cropHeight <= 0) {
            throw IllegalArgumentException("Invalid crop dimensions: width=$cropWidth, height=$cropHeight")
        }
    
        return Bitmap.createBitmap(
            bitmap,
            leftOffset.toInt(),
            topOffset.toInt(),
            cropWidth.toInt(),
            cropHeight.toInt()
        )
    }

    fun dispose() {
        job.cancel()
        synchronized(tessLock) {
            try { tessApi?.recycle() } catch (_: Throwable) {
                // tesseract4android exposes recycle() and stop(); end() is from
                // the older tess-two binding and is not available here.
                try { tessApi?.stop() } catch (_: Throwable) {}
            }
            tessApi = null
        }
    }
}

