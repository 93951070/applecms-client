import AVKit
import Flutter
import UIKit

/// 系统画中画（Picture-in-Picture）支持。
///
/// Flutter 侧通过 `echotv/pip` 通道控制：
/// - isSupported：系统是否支持 PiP
/// - setEnabled：播放器就绪后创建 PiP 控制器并允许离开 App 时自动进入
/// - enter：主动进入 PiP
///
/// 官方 video_player 在 iOS 上基于 AVPlayer + AVPlayerLayer，这里在视图层级中
/// 找到正在播放的 AVPlayerLayer 并交给 AVPictureInPictureController 接管。
/// 进出 PiP 时反向通知 Flutter，使其在 PiP 期间保持播放。
@main
@objc class AppDelegate: FlutterAppDelegate {
  private var pipController: AVPictureInPictureController?
  private var pipChannel: FlutterMethodChannel?

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

  /// 播放器就绪时建立控制器并开启「离开 App 自动进入画中画」。
  private func setPipEnabled(_ enabled: Bool) {
    if enabled {
      setupPipController()
    } else {
      pipController = nil
    }
  }

  private func setupPipController() {
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
    if let existing = pipController, existing.isPictureInPicturePossible { return }
    guard let layer = findPlayerLayer(from: window) else { return }
    let controller = AVPictureInPictureController(playerLayer: layer)
    controller?.delegate = self
    if #available(iOS 14.2, *) {
      controller?.canStartPictureInPictureAutomaticallyFromInline = true
    }
    pipController = controller
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
