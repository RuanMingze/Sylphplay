/// iOS 锁屏/控制中心 Now Playing 单行歌词桥接。
///
/// just_audio_background 的 MediaItem 没暴露 lyrics 字段，
/// 直接原生调 MPNowPlayingInfoCenter（iOS 13+ 支持 MPNowPlayingInfoPropertyLyrics）。
///
/// 同时负责「视频后台播放」桥接：Dart 层告知原生当前视频是否在播，
/// 原生在 applicationDidEnterBackground 里显式保持 AVAudioSession active，
/// 让 video_player 插件内部的 AVPlayer 继续解码音轨（画面冻结，声音继续）。
library;

import 'dart:io' show Platform;
import 'package:flutter/services.dart';

const _kNpCh = MethodChannel('cn.ruanftrix.sylphplay/nowplaying');
const _kVideoBgCh = MethodChannel('cn.ruanftrix.sylphplay/videobg');

/// 把当前歌词行推到 iOS 锁屏/控制中心
Future<void> setLockscreenLyrics(String text) async {
  if (!Platform.isIOS) return;
  try { await _kNpCh.invokeMethod('setLyrics', {'text': text}); } catch (_) {}
}

/// 清空锁屏歌词（换歌 / 切到图片/视频 / 关闭歌词）
Future<void> clearLockscreenLyrics() async {
  if (!Platform.isIOS) return;
  try { await _kNpCh.invokeMethod('clearLyrics'); } catch (_) {}
}

/// 告知原生：当前是否有视频在播放。
/// true  → App 进后台时原生保持 AVAudioSession active，AVPlayer 音轨继续解码
/// false → 恢复普通行为（iOS 后台默认会 pause 非 audio_service 的播放器）
Future<void> setVideoPlayingInBackground(bool playing) async {
  if (!Platform.isIOS) return;
  try { await _kVideoBgCh.invokeMethod('setVideoPlaying', {'playing': playing}); } catch (_) {}
}
