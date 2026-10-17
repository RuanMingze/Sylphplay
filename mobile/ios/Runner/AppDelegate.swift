import Flutter
import UIKit
import MediaPlayer
import AVFoundation

/// iOS 锁屏歌词私有键。Apple 没公开 MPNowPlayingInfoPropertyLyrics 常量，
/// 用运行时字符串键直接塞到 nowPlayingInfo 里（iOS 13+ 实测生效）。
private let kMPLyrics = "__MPNowPlayingInfoPropertyLyrics"

@main
@objc class AppDelegate: FlutterAppDelegate {
  /// 当前视频是否正在播放（Dart 层通过 MethodChannel 设）。
  /// 如果是 true，进后台时显式保持 AVAudioSession active，让 AVPlayer（video_player 插件）继续解码音轨。
  private var videoPlayingInBackground = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 【Flutter 默认模板的正确顺序：先注册插件，再调 super】
    // FlutterAppDelegate 本身实现了 FlutterPluginRegistry，传 self 就行
    // 顺序反了 → super 里先创建 FlutterEngine → 插件还没注册 → JustAudioBackground.init() 永远等 → 白屏
    GeneratedPluginRegistrant.register(with: self)

    let ok = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    // super 之后 window.rootViewController 才被赋值，拿 messenger 注册自定义 MethodChannel
    if let controller = window?.rootViewController as? FlutterViewController {
      setupChannels(messenger: controller.binaryMessenger)
    }
    return ok
  }

  // MARK: - 生命周期：视频后台播放保持 AVAudioSession active

  override func applicationWillResignActive(_ application: UIApplication) {
    super.applicationWillResignActive(application)
    ensureAudioSessionActive(forVideo: videoPlayingInBackground)
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    super.applicationDidEnterBackground(application)
    if videoPlayingInBackground {
      ensureAudioSessionActive(forVideo: true)
    }
  }

  override func applicationWillEnterForeground(_ application: UIApplication) {
    super.applicationWillEnterForeground(application)
    if videoPlayingInBackground {
      try? AVAudioSession.sharedInstance().setActive(false, options: [])
    }
  }

  private func ensureAudioSessionActive(forVideo: Bool) {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      if forVideo {
        try session.setActive(true, options: [])
      }
    } catch {
      NSLog("[Sylphplay] ensureAudioSessionActive failed: \(error)")
    }
  }

  // MARK: - MethodChannel 注册

  private func setupChannels(messenger: FlutterBinaryMessenger) {
    // 锁屏歌词桥接
    let lyricsChannel = FlutterMethodChannel(name: "cn.ruanftrix.sylphplay/nowplaying", binaryMessenger: messenger)
    lyricsChannel.setMethodCallHandler { (call, result) in
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

    // 视频后台播放桥接
    let bgCh = FlutterMethodChannel(name: "cn.ruanftrix.sylphplay/videobg", binaryMessenger: messenger)
    bgCh.setMethodCallHandler { (call, result) in
      switch call.method {
      case "setVideoPlaying":
        self.videoPlayingInBackground = (call.arguments as? [String: Any])?["playing"] as? Bool ?? false
        if self.videoPlayingInBackground {
          self.ensureAudioSessionActive(forVideo: true)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// 设置 iOS 锁屏 / 控制中心 Now Playing 的单行歌词
  private func setNowPlayingLyrics(_ text: String) {
    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    if text.isEmpty {
      info.removeValue(forKey: kMPLyrics)
    } else {
      info[kMPLyrics] = text
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }
}
