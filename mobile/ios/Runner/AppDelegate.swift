import Flutter
import UIKit
import MediaPlayer
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// 当前视频是否正在播放（Dart 层通过 MethodChannel 设）。
  /// 如果是 true，进后台时显式保持 AVAudioSession active，让 AVPlayer（video_player 插件）继续解码音轨。
  private var videoPlayingInBackground = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let ok = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    return ok
  }

  // MARK: - 生命周期：视频后台播放保持 AVAudioSession active

  override func applicationWillResignActive(_ application: UIApplication) {
    super.applicationWillResignActive(application)
    ensureAudioSessionActive(forVideo: videoPlayingInBackground)
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    super.applicationDidEnterBackground(application)
    // 进后台时如果视频正在播：强制保持 AVAudioSession active，
    // 让 video_player 插件内部的 AVPlayer 继续解码音轨（声音不会停）。
    // 画面会自动冻结——iOS 不允许视频画面在后台继续渲染，但音频可以。
    if videoPlayingInBackground {
      ensureAudioSessionActive(forVideo: true)
    }
  }

  override func applicationWillEnterForeground(_ application: UIApplication) {
    super.applicationWillEnterForeground(application)
    // 前台不需要后台 session——让 audio_session 包或 just_audio_background 接管
    if videoPlayingInBackground {
      try? AVAudioSession.sharedInstance().setActive(false, options: [])
    }
  }

  /// 确保 AVAudioSession 处于 .playback category + active 状态。
  /// video_player 插件的 AVPlayer 音轨默认就挂在这个 session 上，
  /// session active 时系统不会掐掉音轨解码。
  private func ensureAudioSessionActive(forVideo: Bool) {
    let session = AVAudioSession.sharedInstance()
    do {
      // category: .playback —— 唯一允许后台音频的 category
      // mode: .default —— 视频也用 default（不是 .moviePlayback，那个是给 AVPlayerLayer 视频播放的）
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      if forVideo {
        try session.setActive(true, options: [])
      }
    } catch {
      NSLog("[Sylphplay] ensureAudioSessionActive failed: \(error)")
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    guard let controller = engineBridge.viewController else { return }
    let messenger = controller.binaryMessenger

    // MARK: - Sylphplay 锁屏歌词桥接（上一轮加的）
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

    // MARK: - Sylphplay 视频后台播放桥接
    // Dart 层视频开始播时 set(true)，暂停/结束时 set(false)；原生生命周期据此保持 AVAudioSession active
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
      info.removeValue(forKey: MPNowPlayingInfoPropertyLyrics)
    } else {
      info[MPNowPlayingInfoPropertyLyrics] = text
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }
}
