import AVFAudio
import AVKit
import Flutter
import UIKit

/// 系统画中画（Picture-in-Picture）支持。
///
/// Flutter 侧通过 `echotv/pip` 通道控制：
/// - isSupported：系统是否支持 PiP
/// - setEnabled：播放器就绪后建立控制器并允许离开 App 时自动进入
/// - enter：主动进入 PiP
///
/// 官方 video_player 在 iOS 上基于 AVPlayer + AVPlayerLayer（platform view），
/// 这里在视图层级中定位正在播放的 AVPlayerLayer 并交给 AVPictureInPictureController。
/// 进出 PiP 时反向通知 Flutter，使其在 PiP 期间保持播放。
@main
@objc class AppDelegate: FlutterAppDelegate {
  private var pipController: AVPictureInPictureController?
  private var pipChannel: FlutterMethodChannel?
  private var pipEnabled = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "echotv/pip",
        binaryMessenger: controller.binaryMessenger)
      pipChannel = channel
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self = self else {
          result(false)
          return
        }
        switch call.method {
        case "isSupported":
          result(AVPictureInPictureController.isPictureInPictureSupported())
        case "setEnabled":
          let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
          self.setPipEnabled(enabled)
          result(true)
        case "enter":
          result(self.startPictureInPicture())
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    // 回到前台后视图层级可能已重建，重新绑定一次，保证下次离开仍能自动进入。
    if pipEnabled {
      setupPipController()
    }
  }

  private func setPipEnabled(_ enabled: Bool) {
    pipEnabled = enabled
    if enabled {
      configureAudioSession()
      setupPipController()
    } else {
      pipController = nil
    }
  }

  /// 画中画与后台播放需要播放类音频会话。
  private func configureAudioSession() {
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {}
  }

  /// 视频 platform view 可能晚于调用就绪，未找到 playerLayer 时短暂轮询重试。
  private func setupPipController(attempt: Int = 0) {
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
    if let existing = pipController, existing.isPictureInPicturePossible { return }
    if let layer = findPlayerLayer(from: window) {
      let controller = AVPictureInPictureController(playerLayer: layer)
      controller?.delegate = self
      if #available(iOS 14.2, *) {
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
      }
      pipController = controller
      return
    }
    if attempt < 12 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        guard let self = self, self.pipEnabled else { return }
        self.setupPipController(attempt: attempt + 1)
      }
    }
  }

  private func startPictureInPicture() -> Bool {
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return false }
    if pipController == nil {
      setupPipController()
    }
    guard let controller = pipController, controller.isPictureInPicturePossible else {
      return false
    }
    controller.startPictureInPicture()
    return true
  }

  private func findPlayerLayer(from view: UIView?) -> AVPlayerLayer? {
    guard let view = view else { return nil }
    if let layer = view.layer as? AVPlayerLayer, layer.player != nil {
      return layer
    }
    for sublayer in view.layer.sublayers ?? [] {
      if let playerLayer = sublayer as? AVPlayerLayer, playerLayer.player != nil {
        return playerLayer
      }
    }
    for subview in view.subviews {
      if let found = findPlayerLayer(from: subview) {
        return found
      }
    }
    return nil
  }

  private func notifyPip(_ active: Bool) {
    pipChannel?.invokeMethod("onPipChanged", arguments: ["isInPip": active])
  }
}

extension AppDelegate: AVPictureInPictureControllerDelegate {
  func pictureInPictureControllerWillStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    // 用 willStart 抢在 App 进入后台、Flutter 收到 paused 之前通知，避免被当成退后台暂停。
    notifyPip(true)
  }

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    notifyPip(true)
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    notifyPip(false)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    notifyPip(false)
  }
}
