package io.github.elmehdaouiahmed.flutter_mrz_scanner_enhanced

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.View
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.fotoapparat.characteristic.LensPosition
import io.fotoapparat.configuration.CameraConfiguration
import io.fotoapparat.configuration.Configuration
import io.fotoapparat.selector.LensPositionSelector
import io.fotoapparat.selector.front

class FlutterMrzScannerPlugin : FlutterPlugin {

    private var staticChannel: MethodChannel? = null
    private var appContext: Context? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        appContext = flutterPluginBinding.applicationContext
        flutterPluginBinding.platformViewRegistry.registerViewFactory(
            "mrzscanner",
            MRZScannerFactory(flutterPluginBinding)
        )
        staticChannel = MethodChannel(flutterPluginBinding.binaryMessenger, "mrzscanner_static").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "scanImage" -> handleScanImage(call, result)
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        staticChannel?.setMethodCallHandler(null)
        staticChannel = null
        appContext = null
        // Release the cached MLKit text recognizer's native resources. MLKit
        // recommends close()-ing recognizers when they are no longer needed;
        // plugin detach is the natural lifetime boundary for our cache.
        MrzOcr.shutdownMlkit()
    }

    private fun handleScanImage(call: MethodCall, result: MethodChannel.Result) {
        val ctx = appContext
        if (ctx == null) {
            result.error("NO_CONTEXT", "Plugin detached", null)
            return
        }
        val bytes = call.argument<ByteArray>("bytes")
        if (bytes == null) {
            result.error("BAD_ARGS", "Missing bytes", null)
            return
        }
        val main = Handler(Looper.getMainLooper())
        Thread {
            try {
                val text = MrzOcr.scanImage(ctx, bytes)
                main.post { result.success(text) }
            } catch (e: IllegalArgumentException) {
                main.post { result.error("DECODE_FAILED", e.message, null) }
            } catch (e: Throwable) {
                main.post { result.error("SCAN_FAILED", e.message, null) }
            }
        }.start()
    }
}

class MRZScannerFactory(private val flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context?, id: Int, o: Any?): PlatformView {

        val ctx = if (context != null) context else flutterPluginBinding.applicationContext;

        return MRZScannerView(ctx, flutterPluginBinding.binaryMessenger, id)
    }
}

class MRZScannerView internal constructor(context: Context, messenger: BinaryMessenger, id: Int) : PlatformView, MethodChannel.MethodCallHandler {
    private val methodChannel: MethodChannel = MethodChannel(messenger, "mrzscanner_$id")
    private val cameraView: FotoapparatCamera = FotoapparatCamera(context, methodChannel)//, messenger)

    override fun getView(): View = cameraView.cameraView

    init {
        methodChannel.setMethodCallHandler(this)
        cameraView.fotoapparat.start()
    }

    override fun dispose() {
        cameraView.fotoapparat.stop()
        // Cancels the SupervisorJob AND recycles the cached TessBaseAPI.
        // Without this, every PlatformView teardown leaked the coroutine
        // job (pre-existing) and now also a native TessBaseAPI handle.
        cameraView.dispose()
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                // Re-arm the persistent-failure detector: a retry reuses this
                // same FotoapparatCamera instance, so without this a latched
                // error state would make the retry silently hang again.
                cameraView.resetErrorState()
                val isFrontCam = call.argument<Boolean>("isFrontCam")
                if (isFrontCam!!) {
                    cameraView.fotoapparat.switchTo(front(), cameraView.configuration)
                }
                cameraView.fotoapparat.start()
                result.success(null)
            }
            "stop" -> {
                cameraView.fotoapparat.stop()
                result.success(null)
            }
            "flashlightOn" -> {
                cameraView.flashlightOn()
                result.success(null)
            }
            "flashlightOff" -> {
                cameraView.flashlightOff()
                result.success(null)
            }
            "takePhoto" -> {
                val shouldCrop = call.argument<Boolean>("crop")
                shouldCrop?.let { cameraView.takePhoto(result, crop = it) }
            }
            else -> {
                result.notImplemented()
            }
        }
    }
}
