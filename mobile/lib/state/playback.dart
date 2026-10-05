import 'dart:async';
import 'dart:io';

import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:video_player/video_player.dart';

/// 统一的媒体句柄：音频（just_audio）与视频（video_player）共用一套控制接口
abstract class MediaHandle {
  String? get sourceId; // 当前加载的源（路径或 URL）
  bool get playing;
  double get positionSec;
  double get durationSec;
  bool get hasDuration;
  Future<void> play();
  Future<void> pause();
  Future<void> seekSec(double sec);
  Future<void> setVolume(double v); // 0~1
  Future<void> setSpeed(double v);
  Future<void> disposeHandle();
}

/// 音频句柄（音乐）
class AudioHandle implements MediaHandle {
  final AudioPlayer player = AudioPlayer();
  String? _src;

  @override
  String? get sourceId => _src;

  @override
  bool get playing => player.playing;

  @override
  double get positionSec => player.position.inMilliseconds / 1000.0;

  @override
  double get durationSec => (player.duration?.inMilliseconds ?? 0) / 1000.0;

  @override
  bool get hasDuration => (player.duration?.inMilliseconds ?? 0) > 0;

  /// 加载源（本地文件用 AudioSource.file；远程用 AudioSource.uri）
  ///
  /// 每个音源都必须挂 MediaItem 标签：just_audio_background 靠它填充通知栏 /
  /// 锁屏的标题、专辑、封面，缺标签会直接抛异常。
  Future<Duration?> load(String pathOrUrl,
      {bool isUrl = false, String? title}) async {
    _src = pathOrUrl;
    final tag = MediaItem(
      id: pathOrUrl,
      title: (title != null && title.isNotEmpty) ? title : pathOrUrl,
      album: 'Sylphplay',
    );
    final src = isUrl
        ? AudioSource.uri(Uri.parse(pathOrUrl), tag: tag)
        : AudioSource.file(pathOrUrl, tag: tag);
    return player.setAudioSource(src);
  }

  /// 以「整条音频队列」为播放列表加载。
  ///
  /// just_audio_background 只有在播放器持有「可前后切换的列表」时，
  /// 才会向 iOS 锁屏/控制中心、Android 通知栏提供「上一项/下一项」，
  /// 并由播放器自行驱动切歌（我们通过 currentIndexStream 同步回队列）。
  /// 单曲 `setAudioSource` 时系统上一项/下一项按钮会因无队列而失效。
  Future<Duration?> loadPlaylist(List<AudioSource> sources, int initialIndex) {
    _src = null;
    return player.setAudioSource(ConcatenatingAudioSource(children: sources), initialIndex: initialIndex, initialPosition: Duration.zero);
  }

  @override
  Future<void> play() => player.play();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> seekSec(double sec) async {
    final ms = (sec * 1000).round().clamp(0, 1 << 31);
    await player.seek(Duration(milliseconds: ms));
  }

  @override
  Future<void> setVolume(double v) => player.setVolume(v.clamp(0.0, 1.0));

  @override
  Future<void> setSpeed(double v) => player.setSpeed(v);

  @override
  Future<void> disposeHandle() async {
    await player.dispose();
  }
}

/// 视频句柄
class VideoHandle implements MediaHandle {
  VideoPlayerController? _c;
  String? _src;

  VideoPlayerController? get controller => _c;

  @override
  String? get sourceId => _src;

  @override
  bool get playing => _c?.value.isPlaying ?? false;

  @override
  double get positionSec =>
      (_c?.value.position.inMilliseconds ?? 0) / 1000.0;

  @override
  double get durationSec => (_c?.value.duration.inMilliseconds ?? 0) / 1000.0;

  @override
  bool get hasDuration => (_c?.value.duration.inMilliseconds ?? 0) > 0;

  /// 加载源；本地文件需先拷贝到可访问位置或直接用 file 源
  Future<void> load(String pathOrUrl, {bool isUrl = false}) async {
    _src = pathOrUrl;
    final c = isUrl
        ? VideoPlayerController.networkUrl(Uri.parse(pathOrUrl))
        : VideoPlayerController.file(File(pathOrUrl));
    _c = c;
    await c.initialize();
  }

  @override
  Future<void> play() async => _c?.play();

  @override
  Future<void> pause() async => _c?.pause();

  @override
  Future<void> seekSec(double sec) async {
    final ms = (sec * 1000).round();
    await _c?.seekTo(Duration(milliseconds: ms < 0 ? 0 : ms));
  }

  @override
  Future<void> setVolume(double v) async => _c?.setVolume(v.clamp(0.0, 1.0));

  @override
  Future<void> setSpeed(double v) async => _c?.setPlaybackSpeed(v);

  @override
  Future<void> disposeHandle() async {
    await _c?.dispose();
    _c = null;
  }
}

/// 音量渐变控制 —— 对应桌面版 FadeCtl / fadeVol
///
/// 关键点：渐变**被打断时必须把音量落到目标值**。桌面版从 0 淡入，如果只取消
/// 定时器而不落音量，就会永远停在 0，表现为「第一次播放没声音，动一下音量才响」。
class FadeCtl {
  Timer? _timer;
  Timer? _guard;
  MediaHandle? _m;
  double? _pending;

  bool get active => _timer != null || _guard != null;

  /// 停止渐变；若上一次渐变尚未走完，把音量落到它本应的目标值
  void stop() {
    _timer?.cancel();
    _guard?.cancel();
    _timer = null;
    _guard = null;
    final m = _m;
    final p = _pending;
    _m = null;
    _pending = null;
    if (m != null && p != null) {
      _lastVol = p;
      _apply(m, p);
    }
  }

  /// 将句柄音量在 ms 内渐变到 target；中途再次调用会取消上一次渐变
  void fade(MediaHandle m, double target, int ms, {void Function()? onDone}) {
    stop();
    final start = _lastVol;
    final dur = ms < 1 ? 300 : ms;
    final t0 = DateTime.now().millisecondsSinceEpoch;
    _m = m;
    _pending = target;

    void finish() {
      _timer?.cancel();
      _guard?.cancel();
      _timer = null;
      _guard = null;
      _m = null;
      _pending = null;
      _lastVol = target;
      _apply(m, target);
    }

    void tick() {
      final p =
          ((DateTime.now().millisecondsSinceEpoch - t0) / dur).clamp(0.0, 1.0);
      final v = start + (target - start) * p;
      _lastVol = v;
      _apply(m, v);
      if (p < 1) {
        _timer = Timer(const Duration(milliseconds: 16), tick);
      } else {
        finish();
        onDone?.call();
      }
    }

    tick();
    // 兜底：即使 tick 链被意外打断，dur 之后也一定落到目标音量
    _guard = Timer(Duration(milliseconds: dur + 60), () {
      if (_m == m && _pending == target) finish();
    });
  }

  static void _apply(MediaHandle m, double v) {
    m.setVolume(v).catchError((Object _) {});
  }

  double _lastVol = 1;
  void setLastVol(double v) => _lastVol = v;
}