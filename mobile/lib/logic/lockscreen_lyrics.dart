/// iOS 锁屏/控制中心 Now Playing 单行歌词桥接。
///
/// just_audio_background 的 MediaItem 没暴露 lyrics 字段，
/// 直接原生调 MPNowPlayingInfoCenter（iOS 13+ 支持 MPNowPlayingInfoPropertyLyrics）。
///
/// Android 等其他平台：当前为 no-op（Android MediaSession 的 caption 属性
/// 可以后续用 audio_service 的 extras 接入，不影响架构）。
library;

import 'dart:io' show Platform;
import 'package:flutter/services.dart';

const MethodChannel _ch = MethodChannel('cn.ruanftrix.sylphplay/nowplaying');

/// 把当前歌词行推到 iOS 锁屏/控制中心
Future<void> setLockscreenLyrics(String text) async {
  if (!Platform.isIOS) return;
  try { await _ch.invokeMethod('setLyrics', {'text': text}); } catch (_) {}
}

/// 清空锁屏歌词（换歌 / 切到图片/视频 / 关闭歌词）
Future<void> clearLockscreenLyrics() async {
  if (!Platform.isIOS) return;
  try { await _ch.invokeMethod('clearLyrics'); } catch (_) {}
}
