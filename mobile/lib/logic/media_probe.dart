import 'dart:io';

import 'package:flutter/services.dart';

import '../models/media_item.dart';

/// 媒体类型内容嗅探 —— 扩展名不可用时的兜底判定
///
/// Android SAF 把文件复制到应用缓存时会把名字换成 MediaStore 的 title，
/// 实测 `周杰伦-搁浅.mp3` 会变成 path/name 都是 `搁浅`，扩展名彻底丢失。
/// 桌面版靠扩展名分类就够（Electron 拿得到真实文件名），移动端必须补这条：
/// 交给平台解码器按内容判定（MediaMetadataRetriever → BitmapFactory）。
///
/// 判定失败返回 null，调用方按「不支持」处理，不猜测类型。
class MediaProbeService {
  MediaProbeService._();
  static final MediaProbeService instance = MediaProbeService._();

  static const MethodChannel _ch = MethodChannel('sylph/probe');

  bool get available => Platform.isAndroid;

  /// 返回 image / video / audio；无法判定返回 null
  Future<MediaType?> kind(String path) async {
    if (!available) return null;
    try {
      final s = await _ch.invokeMethod<String>('kind', {'path': path});
      return switch (s) {
        'image' => MediaType.image,
        'video' => MediaType.video,
        'audio' => MediaType.audio,
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }
}