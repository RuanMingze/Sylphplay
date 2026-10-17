import Flutter
import UIKit
import MediaPlayer

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let ok = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    return ok
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // MARK: - Sylphplay 锁屏歌词桥接
    // iOS 13+ 支持 MPNowPlayingInfoPropertyLyrics（系统控件单行显示）
    // just_audio_background 的 MediaItem 没暴露 lyrics 字段，直接原生绕过
    if let controller = engineBridge.viewController {
      let channel = FlutterMethodChannel(name: "cn.ruanftrix.sylphplay/nowplaying", binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { (call, result) in
        switch call.method {
        case "setLyrics":
          let text = (call.arguments as? [String: Any])?["text"] as? String ?? ""
          self.setNowPlayingLyrics(text)
          result(nil)
        case "clearLyrics":
          self.setNowPlayingLyrics("")
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  /// 设置 iOS 锁屏 / 控制中心 Now Playing 的单行歌词
  private func setNowPlayingLyrics(_ text: String) {
    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    if text.isEmpty {
      info.removeValue(forKey: MPNowPlayingInfoPropertyLyrics)
    } else {
      info[MPNowPlayingInfoPropertyLyrics] = text
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }
}
