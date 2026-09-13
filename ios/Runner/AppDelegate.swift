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
        case "status":
          result(self.statusString())
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
      NSLog("echotv: applicationWillResignActive 重新绑定画中画")
      rebindPipController(force: true)
      attemptAutoStartPip()
      broadcastStatus()
    }
  }

  /// 离开 App 时的兜底：若视频正在播放且系统允许，主动启动画中画。
  ///
  /// 自动进入（canStartPictureInPictureAutomaticallyFromInline）在部分机型/时机下
  /// 不触发，这里在后台化前短暂重试，确保「上滑回桌面」也能无缝进入小窗。
  private func attemptAutoStartPip(attempt: Int = 0) {
    guard pipEnabled else { return }
    if pipController?.isPictureInPictureActive == true { return }
    if pipController == nil {
      rebindPipController(force: true)
    }
    guard let controller = pipController else {
      if attempt < 6 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
          self?.attemptAutoStartPip(attempt: attempt + 1)
        }
      }
      return
    }
    let playing = (controller.playerLayer.player?.rate ?? 0) > 0
    if controller.isPictureInPicturePossible && playing {
      NSLog("echotv: 后台前主动启动画中画 attempt=\(attempt)")
      controller.startPictureInPicture()
      return
    }
    if attempt < 8 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
        self?.attemptAutoStartPip(attempt: attempt + 1)
      }
    } else {
      NSLog("echotv: 主动启动画中画放弃 possible=\(controller.isPictureInPicturePossible) playing=\(playing)")
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
    NSLog("echotv: setPipEnabled(\(enabled)) supported=\(AVPictureInPictureController.isPictureInPictureSupported())")
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
    if let layer = findPlayerLayer() {
      if !force, let existing = pipController, existing.playerLayer === layer {
        return
      }
      let controller = AVPictureInPictureController(playerLayer: layer)
      controller?.delegate = self
      if #available(iOS 14.2, *) {
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
      }
      pipController = controller
      NSLog("echotv: rebindPipController 绑定成功 attempt=\(attempt) controller=\(controller != nil)")
      broadcastStatus()
      // 绑定后短时间内打印可用性，便于确认系统是否允许进入画中画。
      for delay in [0.3, 1.0, 2.0] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
          guard let c = self?.pipController else { return }
          NSLog("echotv: PiP possible=\(c.isPictureInPicturePossible) active=\(c.isPictureInPictureActive) delay=\(delay)")
          self?.broadcastStatus()
        }
      }
      return
    }
    if attempt == 0 || attempt == 12 {
      NSLog("echotv: rebindPipController 未找到 AVPlayerLayer attempt=\(attempt) 层级=\(describeLayers(from: window))")
      broadcastStatus()
    }
    if attempt < 12 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        guard let self = self, self.pipEnabled else { return }
        self.rebindPipController(force: force, attempt: attempt + 1)
      }
    }
  }

  /// 打印视图树中的图层类名，用于确认平台视图里是否存在 AVPlayerLayer。
  private func describeLayers(from view: UIView?, depth: Int = 0) -> String {
    guard let view = view, depth <= 6 else { return "" }
    var parts: [String] = []
    for layer in view.layer.sublayers ?? [] {
      let name = String(describing: type(of: layer))
      if name.contains("PlayerLayer") {
        let hasPlayer = (layer as? AVPlayerLayer)?.player != nil
        parts.append("\(name)(player=\(hasPlayer))")
      } else if depth < 4 {
        parts.append(name)
      }
    }
    var result = "depth\(depth)[\(parts.joined(separator: ","))]"
    for sub in view.subviews where depth < 6 {
      let nested = describeLayers(from: sub, depth: depth + 1)
      if !nested.isEmpty {
        result += " " + nested
      }
    }
    return result
  }

  private func startPictureInPicture() -> Bool {
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return false }
    if pipController == nil || pipController?.playerLayer == nil {
      rebindPipController(force: true)
    }
    guard let controller = pipController, controller.isPictureInPicturePossible else {
      NSLog("echotv: enter 失败 controller=\(pipController != nil) possible=\(pipController?.isPictureInPicturePossible ?? false)")
      return false
    }
    controller.startPictureInPicture()
    return true
  }

  /// 找到当前可用的 AVPlayerLayer。
  ///
  /// 遍历所有 window（Flutter 平台视图可能不在 key window 上），并优先返回
  /// 正在播放的图层，避免命中已废弃/暂停的旧图层导致画中画不可用。
  private func findPlayerLayer() -> AVPlayerLayer? {
    var layers: [AVPlayerLayer] = []
    for window in allWindows() {
      collectPlayerLayers(from: window, into: &layers)
    }
    if layers.isEmpty { return nil }
    if let playing = layers.first(where: { ($0.player?.rate ?? 0) > 0 }) {
      return playing
    }
    if let ready = layers.first(where: { $0.player?.currentItem?.status == .readyToPlay }) {
      return ready
    }
    return layers.first
  }

  private func allWindows() -> [UIWindow] {
    var result: [UIWindow] = []
    if let key = window { result.append(key) }
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for candidate in windowScene.windows where !result.contains(where: { $0 === candidate }) {
        result.append(candidate)
      }
    }
    return result
  }

  private func collectPlayerLayers(from view: UIView?, into layers: inout [AVPlayerLayer]) {
    guard let view = view else { return }
    if let layer = view.layer as? AVPlayerLayer, layer.player != nil {
      layers.append(layer)
    }
    for sublayer in view.layer.sublayers ?? [] {
      if let layer = sublayer as? AVPlayerLayer, layer.player != nil {
        layers.append(layer)
      }
    }
    for subview in view.subviews {
      collectPlayerLayers(from: subview, into: &layers)
    }
  }

  /// 汇总画中画运行状态，供 App 内展示与问题定位。
  private func statusString() -> String {
    let supported = AVPictureInPictureController.isPictureInPictureSupported()
    var layerCount = 0
    var playingCount = 0
    for window in allWindows() {
      var layers: [AVPlayerLayer] = []
      collectPlayerLayers(from: window, into: &layers)
      layerCount += layers.count
      playingCount += layers.filter { ($0.player?.rate ?? 0) > 0 }.count
    }
    let controller = pipController
    return "supported=\(supported) layers=\(layerCount) playing=\(playingCount) "
      + "controller=\(controller != nil) possible=\(controller?.isPictureInPicturePossible ?? false) "
      + "active=\(controller?.isPictureInPictureActive ?? false) enabled=\(pipEnabled)"
  }

  private func broadcastStatus() {
    pipChannel?.invokeMethod("onPipStatus", arguments: statusString())
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
