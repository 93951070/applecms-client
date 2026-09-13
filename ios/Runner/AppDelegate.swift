import AVFAudio
import AVKit
import Flutter
import UIKit

/// 系统画中画（Picture in Picture）支持。
///
/// Flutter 侧通过 `echotv/pip` 通道控制：
/// - isSupported：系统是否支持 PiP
/// - setEnabled：播放器就绪后绑定 PiP 来源，允许离开 App 时自动进入
/// - enter：主动进入 PiP
///
/// iOS 的 AVPictureInPictureController 必须以 AVPlayerLayer 为来源。App 的播放器
/// 在 iOS 上使用 `VideoViewType.platformView` 渲染，视图树中存在 AVPlayerLayer，
/// 这里在播放器就绪、全屏切换、前后台切换时重新定位并绑定它。
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

  override func applicationWillResignActive(_ application: UIApplication) {
    super.applicationWillResignActive(application)
    // 离开 App 前重新绑定到当前可见的 AVPlayerLayer（全屏切换会重建平台视图），
    // 让系统在进入后台时能自动进入画中画。
    if pipEnabled {
      rebindPipController(force: true)
    }
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    // 回到前台后视图层级可能已重建，重新绑定，保证下次离开仍能自动进入。
    if pipEnabled {
      rebindPipController(force: true)
    }
  }

  private func setPipEnabled(_ enabled: Bool) {
    pipEnabled = enabled
    if enabled {
      configureAudioSession()
      rebindPipController(force: true)
    } else {
      if pipController?.isPictureInPictureActive == true {
        pipController?.stopPictureInPicture()
      }
      pipController?.delegate = nil
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

  /// 把画中画控制器绑定到当前播放器图层。
  ///
  /// 平台视图可能晚于调用挂载，未找到 AVPlayerLayer 时短暂轮询重试；`force`
  /// 用于全屏切换、回到前台等图层可能已更换的场景。
  private func rebindPipController(force: Bool = false, attempt: Int = 0) {
    guard pipEnabled, AVPictureInPictureController.isPictureInPictureSupported() else { return }
    // 画中画进行中不重建，避免打断当前小窗。
    if pipController?.isPictureInPictureActive == true { return }
    if let layer = findPlayerLayer(from: window) {
      if !force, let existing = pipController, existing.playerLayer === layer {
        return
      }
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
        self.rebindPipController(force: force, attempt: attempt + 1)
      }
    }
  }

  private func startPictureInPicture() -> Bool {
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return false }
    if pipController == nil || pipController?.playerLayer == nil {
      rebindPipController(force: true)
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
    // 停止后解绑，下次播放或回到前台时重新绑定到最新图层。
    pipController = nil
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
      @escaping (Bool) -> Void
  ) {
    // 用户点击画中画的「还原」按钮：通知 Flutter 侧，同时让系统把 App 拉回前台。
    notifyPip(false)
    completionHandler(true)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    notifyPip(false)
    NSLog("echotv: PiP 启动失败: \(error.localizedDescription)")
  }
}
