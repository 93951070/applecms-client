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
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                "setEnabled" -> {
                    pipEnabled = call.argument<Boolean>("enabled") ?: false
                    result.success(true)
                }
                "enter" -> result.success(enterPip())
                else -> result.notImplemented()
            }
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (pipEnabled &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
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
                .setAspectRatio(Rational(16, 9))
                .build()
            enterPictureInPictureMode(params)
        } catch (_: Exception) {
            false
        }
    }
}
