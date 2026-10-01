import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// 音频频谱服务 —— 对应桌面版 WebAudio AnalyserNode 的 getByteFrequencyData
///
/// 移动端通过平台通道把 Android Visualizer 的频域数据（64 段，0~1 归一化）推上来。
/// 若设备/权限不支持，则 [available] 为 false，频谱页按「无 analyser」处理（空频谱），
/// 与桌面版 drawEmptyViz 的行为一致，绝不绘制伪造波形。
class VisualizerService {
  VisualizerService._();
  static final VisualizerService instance = VisualizerService._();

  static const MethodChannel _method = MethodChannel('sylph/visualizer');
  static const EventChannel _events = EventChannel('sylph/visualizer/bands');

  Stream<List<double>>? _stream;
  bool _started = false;

  bool get available => Platform.isAndroid;

  /// 64 段归一化幅度（0~1）
  Stream<List<double>> get bands {
    _stream ??= _events.receiveBroadcastStream().map((event) {
      if (event is List) {
        return event.map((e) => (e is num) ? e.toDouble() : 0.0).toList();
      }
      return const <double>[];
    });
    return _stream!;
  }

  Future<void> start() async {
    if (!available || _started) return;
    _started = true;
    try {
      await _method.invokeMethod<bool>('start');
    } catch (_) {
      // 权限不足或设备不支持：保持静默，频谱保持空态
    }
  }

  Future<void> stop() async {
    if (!available || !_started) return;
    _started = false;
    try {
      await _method.invokeMethod<bool>('stop');
    } catch (_) {}
  }
}