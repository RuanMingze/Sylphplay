import 'dart:io';

import 'package:flutter/services.dart';

/// 视频抽帧缩略图 —— 对应桌面版 captureVideoThumb()
///
/// 走 Android 原生 MediaMetadataRetriever，不再依赖已停止维护的 video_thumbnail
/// （那个包的 android/build.gradle 引用了 Gradle 9 已移除的 jcenter()）。
///
/// 抽帧时间点由原生侧统一决定：前 25% 处，避开开头黑屏；越界则取中点。
class VideoThumbService {
  VideoThumbService._();
  static final VideoThumbService instance = VideoThumbService._();

  static const MethodChannel _ch = MethodChannel('sylph/thumb');

  bool get available => Platform.isAndroid;

  /// 抽帧并返回 JPEG 字节；不支持或失败返回 null（UI 侧退化为图标）
  ///
  /// [atMs] 传 0 或不传时，由原生按「前 25%」规则自行定位。
  Future<Uint8List?> frame(String path, {int atMs = 0}) async {
    if (!available) return null;
    try {
      return await _ch.invokeMethod<Uint8List>('frame', {
        'path': path,
        'atMs': atMs,
      });
    } catch (_) {
      return null;
    }
  }
}