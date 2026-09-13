package com.hoowhoami.echotv

import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 系统画中画（Picture-in-Picture）支持。
 *
 * Flutter 侧通过 `echotv/pip` 通道控制：
 * - isSupported：判断系统是否支持 PiP（Android 8.0+）
 * - setEnabled：播放器是否允许自动进入 PiP（用户按下 Home / 切后台时）
 * - enter：主动进入 PiP
 *
 * 原生在进出 PiP 时反向通知 `onPipChanged`，Flutter 据此在 PiP 期间保持播放。
 */
class MainActivity : FlutterActivity() {
    private val channelName = "echotv/pip"
    private var pipEnabled = false
    private var aspectRatio = Rational(16, 9)
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                "setEnabled" -> {
                    pipEnabled = call.argument<Boolean>("enabled") ?: false
                    call.argument<Double>("aspectRatio")?.let { setAspectRatio(it) }
                    applyPipParams()
                    result.success(true)
                }
                "enter" -> {
                    call.argument<Double>("aspectRatio")?.let { setAspectRatio(it) }
                    result.success(enterPip())
                }
                else -> result.notImplemented()
            }
        }
    }

    /** 视频比例收敛到系统允许的画中画比例区间，避免设置非法值抛异常。 */
    private fun setAspectRatio(ratio: Double) {
        val min = 1.0 / 2.39
        val max = 2.39
        val clamped = ratio.coerceIn(min, max)
        aspectRatio = Rational((clamped * 1000).toInt(), 1000)
    }

    /** 开启后 Android 12+ 交给系统在离开 App 时无缝自动进入画中画。 */
    private fun applyPipParams() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            val builder = PictureInPictureParams.Builder().setAspectRatio(aspectRatio)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                builder.setAutoEnterEnabled(pipEnabled)
                builder.setSeamlessResizeEnabled(true)
            }
            setPictureInPictureParams(builder.build())
        } catch (_: Exception) {
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Android 12+ 由 setAutoEnterEnabled 交给系统自动进入，避免重复触发。
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            pipEnabled &&
            !isInPictureInPictureMode
        ) {
            enterPip()
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        channel?.invokeMethod("onPipChanged", mapOf("isInPip" to isInPictureInPictureMode))
    }

    private fun enterPip(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(aspectRatio)
                .build()
            enterPictureInPictureMode(params)
        } catch (_: Exception) {
            false
        }
    }
}
