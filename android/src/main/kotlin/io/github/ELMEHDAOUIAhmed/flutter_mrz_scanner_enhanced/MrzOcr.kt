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
import com.googlecode.tesseract.android.TessBaseAPI
import java.io.ByteArrayInputStream
import java.io.File

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
     * Decode bytes (JPEG/PNG/etc.), apply EXIF orientation, preprocess, OCR.
     * Returns recognized text, or null if Tesseract found nothing.
     * Throws [IllegalArgumentException] if the bytes cannot be decoded.
     */
    fun scanImage(context: Context, bytes: ByteArray): String? {
        ensureTrainedData(context)
        val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            ?: throw IllegalArgumentException("Unable to decode image bytes")
        var oriented: Bitmap = decoded
        var processed: Bitmap? = null
        try {
            oriented = applyExif(decoded, bytes)
            processed = preprocess(oriented)
            val text = runTesseract(context, processed)
            return if (text.isNullOrBlank()) null else text
        } finally {
            if (processed != null && processed !== oriented) processed.recycle()
            if (oriented !== decoded) oriented.recycle()
            decoded.recycle()
        }
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
