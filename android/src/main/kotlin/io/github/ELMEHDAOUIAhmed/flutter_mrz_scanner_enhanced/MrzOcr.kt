package io.github.elmehdaouiahmed.flutter_mrz_scanner_enhanced

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Matrix
import android.graphics.Paint
import androidx.exifinterface.media.ExifInterface
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import com.googlecode.tesseract.android.TessBaseAPI
import java.io.ByteArrayInputStream
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Single source of truth for the Tesseract OCR pipeline used by both the live
 * camera frame path ([FotoapparatCamera]) and the static `MRZScanner.scanImage`
 * path (registered on the global `mrzscanner_static` MethodChannel).
 *
 * The trained-data file (`ocrb.traineddata`) is extracted lazily on first use
 * into `context.cacheDir/tessdata/` and reused for the lifetime of the process.
 */
object MrzOcr {
    private const val TESS_LANG = "ocrb"
    private const val TESS_WHITELIST = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789<"
    private val PAGE_SEG_MODE = TessBaseAPI.PageSegMode.PSM_SINGLE_BLOCK

    @Volatile
    private var trainedDataReady = false

    // ML Kit text recognizer reused for the lifetime of the plugin. MLKit
    // recommends a single recognizer instance — its native resources are
    // released via [shutdownMlkit] from FlutterMrzScannerPlugin.onDetachedFromEngine.
    @Volatile
    private var mlkitRecognizer: TextRecognizer? = null
    private val mlkitLock = Any()

    private fun getMlkitRecognizer(): TextRecognizer {
        mlkitRecognizer?.let { return it }
        synchronized(mlkitLock) {
            mlkitRecognizer?.let { return it }
            val r = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
            mlkitRecognizer = r
            return r
        }
    }

    /** Release the cached MLKit recognizer. Called on plugin detach. */
    fun shutdownMlkit() {
        synchronized(mlkitLock) {
            mlkitRecognizer?.close()
            mlkitRecognizer = null
        }
    }

    // NOTE: This singleton API is the static-path cache (app-lifetime).
    // The live camera path (FotoapparatCamera.tessApi) owns its OWN
    // TessBaseAPI keyed to the camera session. Do NOT collapse them — see
    // .planning/phases/02-scan-throughput/02-CONTEXT.md.
    @Volatile
    private var sharedBaseApi: TessBaseAPI? = null
    internal val baseApiLock = Any()

    /**
     * Lazily acquire the process-wide static-path TessBaseAPI. Initialized
     * on first call, never recycled (app-lifetime cache). Concurrent callers
     * (FlutterMrzScannerPlugin.handleScanImage spawns Thread { } per call)
     * must serialize setImage/utF8Text on [baseApiLock].
     */
    internal fun acquireSharedBaseApi(context: Context): TessBaseAPI {
        sharedBaseApi?.let { return it }
        ensureTrainedData(context)
        synchronized(baseApiLock) {
            sharedBaseApi?.let { return it }
            val api = TessBaseAPI()
            api.init(context.cacheDir.absolutePath, TESS_LANG)
            api.setVariable("tessedit_char_whitelist", TESS_WHITELIST)
            api.pageSegMode = PAGE_SEG_MODE
            sharedBaseApi = api
            return api
        }
    }

    /**
     * Reuse-friendly OCR: caller owns [api]; we only setImage + read text.
     * Caller must serialize concurrent calls on [api] externally:
     *   - live path is single-frame-thread (Fotoapparat frame queue),
     *   - static path uses [baseApiLock].
     */
    internal fun runTesseractWith(api: TessBaseAPI, bitmap: Bitmap): String? {
        api.setImage(bitmap)
        val text = api.utF8Text
        return if (text.isNullOrBlank()) null else text
    }

    /** Idempotent + thread-safe trained-data extraction. */
    fun ensureTrainedData(context: Context) {
        if (trainedDataReady) return
        synchronized(this) {
            if (trainedDataReady) return
            val dir = File(context.cacheDir, "tessdata").apply { mkdirs() }
            val file = File(dir, "$TESS_LANG.traineddata")
            if (!file.exists() || file.length() == 0L) {
                file.outputStream().use { out ->
                    context.assets.open("$TESS_LANG.traineddata").use { it.copyTo(out) }
                }
            }
            trainedDataReady = true
        }
    }

    /**
     * Decode bytes (JPEG/PNG/etc.), apply EXIF orientation, run ML Kit
     * on-device text recognition, filter MRZ-shaped lines, and return them
     * joined by `\n` (or null when no MRZ-shaped line is found).
     *
     * Phase 3b: the static still-image path was swapped from Tesseract to
     * ML Kit text recognition. The legacy Tesseract helpers
     * (`acquireSharedBaseApi`, `runTesseractWith`, `preprocess`) are kept
     * because the live camera path ([FotoapparatCamera]) still uses them.
     */
    fun scanImage(context: Context, bytes: ByteArray): String? {
        return scanImageWithMlkit(context, bytes)
    }

    /**
     * Decode bytes (JPEG/PNG/etc.), apply EXIF orientation, run MLKit text
     * recognition. Returns MRZ-shaped lines joined with `\n`, or null.
     */
    private fun scanImageWithMlkit(context: Context, bytes: ByteArray): String? {
        val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            ?: throw IllegalArgumentException("Unable to decode image bytes")
        val oriented = applyExif(decoded, bytes)
        return try {
            // Pre-rotated above, so pass rotationDegrees = 0 (the bitmap is
            // already in its display orientation).
            val input = InputImage.fromBitmap(oriented, 0)
            val recognizer = getMlkitRecognizer()
            // MLKit's process() returns a Task — bridge to sync via a latch.
            // FlutterMrzScannerPlugin.handleScanImage already runs us on a
            // worker thread, so blocking here does not stall the platform thread.
            val latch = CountDownLatch(1)
            var resultText: String? = null
            var failure: Exception? = null
            recognizer.process(input)
                .addOnSuccessListener { text ->
                    resultText = filterMrzLines(text.text)
                    latch.countDown()
                }
                .addOnFailureListener { e ->
                    failure = e
                    latch.countDown()
                }
            if (!latch.await(15, TimeUnit.SECONDS)) {
                throw RuntimeException("MLKit text recognition timed out")
            }
            failure?.let { throw it }
            resultText
        } finally {
            if (oriented !== decoded) oriented.recycle()
            decoded.recycle()
        }
    }

    /** Filter MLKit's recognized text down to MRZ-shaped lines. */
    private fun filterMrzLines(raw: String): String? {
        val mrzLines = raw.split('\n').mapNotNull { line ->
            val normalized = line
                .replace(" ", "")
                .replace("«", "<")
                .uppercase()
            // MRZ alphabet is A-Z, 0-9, < — anything else disqualifies.
            // Shortest valid MRZ line is TD1 at 30 chars; allow a small
            // tolerance for OCR slop on edge characters.
            if (normalized.length >= 28 &&
                normalized.all { it.isLetterOrDigit() || it == '<' } &&
                normalized.any { it == '<' || it.isDigit() }
            ) {
                normalized
            } else {
                null
            }
        }
        return if (mrzLines.isEmpty()) null else mrzLines.joinToString("\n")
    }

    /** Grayscale + binary threshold (port of FotoapparatCamera.preprocessImage). */
    fun preprocess(bitmap: Bitmap): Bitmap {
        val grayscale = Bitmap.createBitmap(bitmap.width, bitmap.height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(grayscale)
        val paint = Paint()
        val colorMatrix = ColorMatrix().apply { setSaturation(0f) }
        paint.colorFilter = ColorMatrixColorFilter(colorMatrix)
        canvas.drawBitmap(bitmap, 0f, 0f, paint)

        val threshold = 128
        val width = grayscale.width
        val height = grayscale.height
        val pixels = IntArray(width * height)
        grayscale.getPixels(pixels, 0, width, 0, 0, width, height)
        for (i in pixels.indices) {
            val gray = Color.red(pixels[i])
            pixels[i] = if (gray < threshold) Color.BLACK else Color.WHITE
        }
        val processed = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        processed.setPixels(pixels, 0, width, 0, 0, width, height)
        grayscale.recycle()
        return processed
    }

    /**
     * Run Tesseract on [bitmap] using the SAME config as the live frame path.
     * Releases native resources via `recycle()` to avoid leaks for the static
     * one-shot path (live path keeps its existing `stop()` semantics).
     */
    @Deprecated(
        message = "Allocates and recycles a TessBaseAPI per call. Use acquireSharedBaseApi(context) + runTesseractWith(api, bitmap) (with appropriate external serialization) instead.",
        replaceWith = ReplaceWith("acquireSharedBaseApi(context).let { api -> synchronized(baseApiLock) { runTesseractWith(api, bitmap) } }")
    )
    internal fun runTesseract(context: Context, bitmap: Bitmap): String? {
        val baseApi = TessBaseAPI()
        return try {
            baseApi.init(context.cacheDir.absolutePath, TESS_LANG)
            baseApi.setVariable("tessedit_char_whitelist", TESS_WHITELIST)
            baseApi.pageSegMode = PAGE_SEG_MODE
            baseApi.setImage(bitmap)
            baseApi.utF8Text
        } finally {
            try {
                baseApi.recycle()
            } catch (_: Throwable) {
                // recycle() may not be available on every binding; fall back to end()/stop().
                try { baseApi.end() } catch (_: Throwable) { try { baseApi.stop() } catch (_: Throwable) {} }
            }
        }
    }

    private fun readExifOrientation(bytes: ByteArray): Int {
        return try {
            ByteArrayInputStream(bytes).use { input ->
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

    private fun applyExif(decoded: Bitmap, bytes: ByteArray): Bitmap {
        val orientation = readExifOrientation(bytes)
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.setScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.setRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> {
                matrix.setRotate(180f); matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.setRotate(90f); matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.setRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.setRotate(-90f); matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.setRotate(-90f)
            else -> return decoded
        }
        return Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
    }
}
