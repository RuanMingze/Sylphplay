import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
// 前缀导入：其 MediaItem 与本项目的 models/media_item.dart 同名，避免冲突
import 'package:just_audio_background/just_audio_background.dart' as jab;
import 'package:shared_preferences/shared_preferences.dart';

import '../logic/auto_lyrics.dart';
import '../logic/lrc.dart';
import '../logic/media_probe.dart';
import '../models/app_settings.dart';
import '../models/media_item.dart';
import 'playback.dart';

/// 队列持久化 key（与桌面版 localStorage 同名）
const _kQueue = 'sylph:queue';
const _kQView = 'sylph:qview';
const _kQFilter = 'sylph:qfilter';
const _kProgress = 'sylph:progress';

/// 渐变（淡入淡出）时长 —— 对应 FX
const int kFxOutMs = 360;
const int kFxInMs = 300;

/// 全局应用状态 —— 对应桌面版 renderer.js 的 S / Lyrics 及其全部业务逻辑
class AppState extends ChangeNotifier {
  AppSettings settings = AppSettings();

  final List<MediaItem> queue = [];
  int current = -1;
  bool playing = false;
  String queueView = 'list'; // list | grid
  bool queuePanelOpen = false;

  /// 本次会话已联网尝试过且失败的路径（避免反复请求）
  final Set<String> _autoLyricsTried = {};

  /// 联网成功的 LRC 缓存
  final Map<String, String> _autoLyricCache = {};

  /// 应用是否处于全屏（沉浸）模式
  bool fullscreen = false;
  /// 全屏时工具栏是否可见（对应 fs-top-show / fs-bottom-show 的合并态）
  bool fsBarsVisible = false;

  String? toastMsg;
  Timer? _toastTimer;

  /// 队列搜索 / 类型筛选（all|image|audio|video）
  String qSearch = '';
  String qFilter = 'all';

  // —— 图片查看器状态 ——
  double imgZoom = 1;
  int imgRot = 0;
  bool imgFitActive = true;
  double imgLeftPct = 50;
  double imgTopPct = 50;
  int imgNatW = 0, imgNatH = 0;
  double stageW = 0, stageH = 0;

  // —— 歌词状态 ——
  final List<LyricLine> lyricLines = [];
  int lyricActiveIdx = -1;
  String? lyricCurPath;

  // —— 国庆彩蛋 ——
  bool nationalForce = false;

  // —— 播放 ——
  final AudioHandle audioHandle = AudioHandle();
  VideoHandle? videoHandle;
  MediaHandle? media; // 当前媒体（音频或视频），图片时为 null
  bool _switchFadeActive = false;
  int? _switchFadeTarget;
  bool _pausingFade = false;
  final FadeCtl _fade = FadeCtl();
  StreamSubscription<PlayerState>? _playerSub;
  /// 队列中「音频项」的下标序列 —— 与 just_audio 播放列表顺序一一对应，
  /// 用于把系统（锁屏/通知栏）切歌后的播放列表下标映射回 queue 下标
  List<int> _audioIdx = [];
  StreamSubscription<int?>? _idxSub;
  /// 系统切歌进行中：避免 currentIndexStream 与本地加载互相重入
  bool _sysSwitching = false;

  int? _shuffleBagPos;
  List<int>? _shuffleBag;

  Timer? _ticker;
  Timer? _progressTimer;
  bool _seeking = false;
  bool _endedFired = false;

  bool _queueRestored = false;

  bool get nationalActive => _isOct1Today() || nationalForce;

  static bool _isOct1Today() {
    final d = DateTime.now();
    return d.month == 10 && d.day == 1;
  }

  MediaItem? get currentItem =>
      (current >= 0 && current < queue.length) ? queue[current] : null;

  MediaType? get activeType => currentItem?.type;

  double get positionSec => media?.positionSec ?? 0;
  double get durationSec => media?.durationSec ?? 0;

  bool get showLyricsView => lyricLines.isNotEmpty;

  /* ============================================================
     初始化
     ============================================================ */
  Future<void> init() async {
    settings = await SettingsStore.load();
    // 国庆彩蛋强制参数通道（对应桌面版 --101）：由编译期 dart-define 注入
    const natParam = String.fromEnvironment('SYLPH_NATIONAL');
    nationalForce = natParam == '101';
    await _restoreQueue();
    final sp = await SharedPreferences.getInstance();
    queueView = sp.getString(_kQView) == 'grid' ? 'grid' : 'list';
    final savedQF = sp.getString(_kQFilter);
    qFilter = (savedQF != null && ['all', 'image', 'audio', 'video'].contains(savedQF))
        ? savedQF
        : 'all';
    queuePanelOpen = queue.isNotEmpty; // 队列有内容则自动展开
    _startTicker();
    _bindPlayerState();
    _bindPlayerIndex();
    _applySpeed();
    notifyListeners();
  }

  /// 后台播放启用后，锁屏 / 控制中心 / 耳机按键会直接操作 AudioPlayer，
  /// 绕开本地的淡入淡出逻辑。这里订阅播放器状态把外部改动立刻同步回 UI，
  /// 并清掉可能残留的 _pausingFade，避免出现「通知栏已暂停、App 里还在转」
  /// 这种错位状态。
  ///
  /// 注意：自然播完（processingState == completed）不在这里处理 —— 那要留给
  /// 下方 ticker 里的 _onEnded，否则会把「刚才还在播」这个判断提前抹掉，
  /// 导致自动下一首失效。
  void _bindPlayerState() {
    _playerSub?.cancel();
    _playerSub = audioHandle.player.playerStateStream.listen((st) {
      if (media is! AudioHandle) return;
      if (st.processingState == ProcessingState.completed) return;
      if (st.playing == playing) return;
      _pausingFade = false;
      playing = st.playing;
      notifyListeners();
    });
  }

  /// 系统切歌同步：锁屏 / 控制中心 / 通知栏点「上一项 / 下一项」时，
  /// just_audio 会在内部播放列表里前进/后退并自动播放。
  /// 这里把播放列表下标映射回 queue 下标，刷新 UI / 歌词 / 进度。
  void _bindPlayerIndex() {
    _idxSub?.cancel();
    _idxSub = audioHandle.player.currentIndexStream.listen((pi) {
      if (pi == null || _sysSwitching) return;
      if (media is! AudioHandle) return;
      if (pi < 0 || pi >= _audioIdx.length) return;
      final qi = _audioIdx[pi];
      if (qi == current) return;
      _sysSwitching = true;
      loadMediaNow(qi, keepSource: true).whenComplete(() => _sysSwitching = false);
    });
  }

  @override
  void dispose() {
    _playerSub?.cancel();
    _idxSub?.cancel();
    _ticker?.cancel();
    _progressTimer?.cancel();
    _toastTimer?.cancel();
    audioHandle.disposeHandle();
    videoHandle?.disposeHandle();
    super.dispose();
  }

  /* ============================================================
     提示（toast）
     ============================================================ */
  void showToast(String msg) {
    toastMsg = msg;
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(milliseconds: 1800), () {
      toastMsg = null;
      notifyListeners();
    });
    notifyListeners();
  }

  /* ============================================================
     设置持久化
     ============================================================ */
  Future<void> saveSettings() => SettingsStore.save(settings);

  Future<void> updateSettings(void Function(AppSettings s) fn,
      {bool apply = true}) async {
    fn(settings);
    await saveSettings();
    if (apply) _applySpeed();
    notifyListeners();
  }

  /// 当前主题是否为深色（theme=system 时跟随系统）
  bool isDark(BuildContext ctx) {
    if (settings.theme == 'dark') return true;
    if (settings.theme == 'light') return false;
    return MediaQuery.of(ctx).platformBrightness == Brightness.dark;
  }

  void toggleTheme() {
    settings.theme = settings.theme == 'dark' ? 'light' : 'dark';
    saveSettings();
    notifyListeners();
  }

  /* ============================================================
     队列：持久化 / 增删 / 排序
     ============================================================ */
  Future<void> _restoreQueue() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_kQueue);
      if (raw != null) {
        final arr = jsonDecode(raw);
        if (arr is List) {
          for (final e in arr) {
            final it = MediaItem.fromJson(e);
            if (it != null) queue.add(it);
          }
        }
      }
    } catch (_) {}
    _queueRestored = true;
  }

  Future<void> _saveQueue() async {
    if (!_queueRestored) return;
    final sp = await SharedPreferences.getInstance();
    if (queue.isEmpty) {
      await sp.remove(_kQueue);
      return;
    }
    await sp.setString(_kQueue, jsonEncode(queue.map((q) => q.toJson()).toList()));
  }

  /// 搜索词 + 类型筛选取子集，并保留各自真实索引 —— 对应 filteredQueue()
  List<({MediaItem it, int qi})> filteredQueue() {
    final kw = qSearch.trim().toLowerCase();
    final f = qFilter;
    final rows = <({MediaItem it, int qi})>[];
    for (var qi = 0; qi < queue.length; qi++) {
      final it = queue[qi];
      if (f != 'all' && it.type.name != f) continue;
      if (kw.isNotEmpty && !it.name.toLowerCase().contains(kw)) continue;
      rows.add((it: it, qi: qi));
    }
    return rows;
  }

  Future<void> addToQueue(List<MediaItem> items) async {
    if (items.isEmpty) return;
    final added = <int>[];
    for (final it in items) {
      if (it.path.isEmpty) continue;
      if (queue.any((q) => q.path == it.path)) continue;
      queue.add(it);
      added.add(queue.length - 1);
    }
    await _saveQueue();
    notifyListeners();
    if (added.isEmpty) {
      showToast('所选内容已在队列中');
      return;
    }
    await loadMedia(added.first); // 新增文件直接播放/显示
    showToast('已添加 ${added.length} 项到队列');
  }

  Future<void> removeFromQueue(int i) async {
    if (i < 0 || i >= queue.length) return;
    queue.removeAt(i);
    if (queue.isEmpty) {
      await stopAll();
      showEmpty();
    } else if (i == current) {
      await loadMedia(math.min(i, queue.length - 1));
    } else if (i < current) {
      current--;
    }
    await _saveQueue();
    notifyListeners();
  }

  /// 拖拽排序 —— 对应 setupDrag 的 drop 处理（含 current 索引修正）
  Future<void> reorderQueue(int from, int to) async {
    if (from == to || from < 0 || from >= queue.length || to < 0 || to >= queue.length) {
      return;
    }
    final moved = queue.removeAt(from);
    queue.insert(to, moved);
    if (current == from) {
      current = to;
    } else if (current > from && current <= to) {
      current--;
    } else if (current < from && current >= to) {
      current++;
    }
    await _saveQueue();
    notifyListeners();
  }

  Future<void> clearQueue() async {
    queue.clear();
    await stopAll();
    showEmpty();
    await _saveQueue();
    notifyListeners();
  }

  void setQueueView(String v) {
    queueView = v;
    SharedPreferences.getInstance().then((sp) => sp.setString(_kQView, v));
    notifyListeners();
  }

  void setQFilter(String f) {
    qFilter = f;
    SharedPreferences.getInstance().then((sp) => sp.setString(_kQFilter, f));
    notifyListeners();
  }

  void setQSearch(String v) {
    qSearch = v;
    notifyListeners();
  }

  /* ---------- 界面态（供 UI 层驱动） ---------- */
  void toggleQueuePanel() {
    queuePanelOpen = !queuePanelOpen;
    notifyListeners();
  }

  void setQueuePanelOpen(bool open) {
    if (queuePanelOpen == open) return;
    queuePanelOpen = open;
    notifyListeners();
  }

  void setFullscreen(bool v) {
    if (fullscreen == v) return;
    fullscreen = v;
    fsBarsVisible = v;
    notifyListeners();
  }

  void setFsBarsVisible(bool v) {
    if (fsBarsVisible == v) return;
    fsBarsVisible = v;
    notifyListeners();
  }

  /* ============================================================
     断点续播
     ============================================================ */
  Future<double> _getSavedProgress(String path) async {
    try {
      final sp = await SharedPreferences.getInstance();
      final m = jsonDecode(sp.getString(_kProgress) ?? '{}');
      if (m is Map && m[path] is num) return (m[path] as num).toDouble();
    } catch (_) {}
    return 0;
  }

  Future<void> _saveProgress(String path, double sec) async {
    if (path.isEmpty || sec < 3) return;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_kProgress);
      final m = <String, dynamic>{};
      if (raw != null) {
        final parsed = jsonDecode(raw);
        if (parsed is Map) {
          var n = 0;
          parsed.forEach((k, v) {
            if (n++ < 400) m[k.toString()] = v; // 限制条目，避免无限膨胀
          });
        }
      }
      m[path] = sec;
      await sp.setString(_kProgress, jsonEncode(m));
    } catch (_) {}
  }

  /// 从记忆位置恢复 —— 对应桌面版 loadedmetadata 中 `p > 2 && p < dur - 1` 的恢复条件
  Future<void> _restoreProgress(String path) async {
    if (!settings.rememberProgress) return;
    final m = media;
    if (m == null || !m.hasDuration) return;
    final dur = m.durationSec;
    if (dur <= 3) return;
    final p = await _getSavedProgress(path);
    if (p > 2 && p < dur - 1) {
      await m.seekSec(p);
    }
  }

  /* ============================================================
     媒体加载 / 播放控制
     ============================================================ */
  bool _isAv(MediaHandle? m) => m != null && (m is AudioHandle || m is VideoHandle);

  /// 渐变切换：先淡出当前音视频，再真正加载新媒体（快速连点合并为最后一次目标）
  Future<void> loadMedia(int idx) async {
    if (idx < 0 || idx >= queue.length) {
      await stopAll();
      showEmpty();
      return;
    }
    _switchFadeTarget = idx;
    final m = media;
    if (_isAv(m) && m!.playing) {
      if (_switchFadeActive) return; // 已在淡出，最新目标由淡出完成时读取
      _switchFadeActive = true;
      _fade.setLastVol(settings.defaultVolume / 100);
      _fade.fade(m, 0, kFxOutMs, onDone: () async {
        _switchFadeActive = false;
        final t = _switchFadeTarget;
        _switchFadeTarget = null;
        if (t != null) await loadMediaNow(t);
      });
    } else {
      await loadMediaNow(idx);
    }
  }

  /// 为音频项构造带 MediaItem 标签的音源（通知栏/锁屏标题、封面依赖它）
  AudioSource _audioSourceFor(MediaItem it) {
    final tag = jab.MediaItem(id: it.path, title: it.name, album: 'Sylphplay');
    return it.url
        ? AudioSource.uri(Uri.parse(it.path), tag: tag)
        : AudioSource.file(it.path, tag: tag);
  }

  /// 按播放模式决定「音频播放列表」的顺序（锁屏切歌与自动续播都按它走）
  ///
  /// - off：只放当前这一首 —— 播完不自动下一首（保持原有语义）
  /// - shuffle / shuffleSmart：当前曲在前，其余随机
  /// - one / all / sequence：按队列原顺序（单曲循环由 LoopMode 负责）
  List<int> _audioOrderFor(int curQueueIdx) {
    final audio = [
      for (var i = 0; i < queue.length; i++)
        if (queue[i].type == MediaType.audio) i
    ];
    final mode = settings.playMode;
    if (mode == PlayMode.off) return [curQueueIdx];
    if (mode == PlayMode.shuffle || mode == PlayMode.shuffleSmart) {
      final rest = [...audio]..remove(curQueueIdx);
      rest.shuffle(math.Random());
      return [curQueueIdx, ...rest];
    }
    return audio;
  }

  /// 播放模式 → just_audio 循环模式（播放器自身负责续播/循环）
  void _applyAudioLoopMode() {
    final mode = settings.playMode;
    final lm = mode == PlayMode.one
        ? LoopMode.one
        : (mode == PlayMode.all ? LoopMode.all : LoopMode.off);
    audioHandle.player.setLoopMode(lm);
  }

  Future<void> loadMediaNow(int idx, {bool keepSource = false}) async {
    if (idx < 0 || idx >= queue.length) {
      await stopAll();
      showEmpty();
      return;
    }
    // keepSource：由系统（锁屏）切歌触发，播放器已自行换曲并开始播放，
    // 不能再暂停/重建播放列表，否则会把刚起的播放打断
    if (keepSource) {
      media = null;
      _endedFired = false;
    } else {
      await _stopCurrent();
    }
    final item = queue[idx];
    current = idx;
    final type = item.type;

    if (type == MediaType.audio) {
      final h = audioHandle;
      if (!keepSource) {
        // 把「音频队列」按播放模式交给播放器：系统上一项/下一项才有内容可切，
        // 自动续播也交给播放器（见 _applyAudioLoopMode），避免与本地点按重复跳曲
        _audioIdx = _audioOrderFor(idx);
        final sources = [for (final i in _audioIdx) _audioSourceFor(queue[i])];
        var initial = _audioIdx.indexOf(idx);
        if (initial < 0) initial = 0;
        try {
          await h.loadPlaylist(sources, initial);
        } catch (_) {
          showToast('无法播放：${item.name}');
        }
        _applyAudioLoopMode();
      }
      media = h;
      _applySpeed();
      await _restoreProgress(item.path);
      notifyListeners();
      await _playMedia();
      // 显示歌词（本地同名 sidecar；缺失且开启实验则联网兜底）
      if (settings.lyricsEnabled) {
        unawaited(autoLoadLyrics(item));
      } else {
        clearLyrics();
      }
    } else if (type == MediaType.video) {
      await videoHandle?.disposeHandle();
      final h = VideoHandle();
      videoHandle = h;
      try {
        await h.load(item.path, isUrl: item.url);
      } catch (_) {
        showToast('无法播放：${item.name}');
      }
      media = h;
      _applySpeed();
      await _restoreProgress(item.path);
      notifyListeners();
      await _playMedia();
      clearLyrics();
    } else {
      // 图片
      resetImgState();
      media = null;
      clearLyrics();
      notifyListeners();
    }
    notifyListeners();
  }

  /// 起播 + 淡入。
  ///
  /// 注意：just_audio 的 `play()` 返回的 Future 要等到「暂停 / 播放结束」才完成，
  /// 绝不能 await —— 一旦 await，后面的淡入代码永远不会执行，音量会一直停在
  /// 起播时设的 0，表现为「第一次播放没声音，动一下音量才响」。
  void _playWithFadeIn(MediaHandle m) {
    final target = settings.defaultVolume / 100;
    playing = true;
    _fade.setLastVol(0);
    _fade.fade(m, target, kFxInMs);
    m.play().catchError((Object _) {
      _fade.stop();
      playing = false;
      m.setVolume(target).catchError((Object _) {});
      notifyListeners();
    });
  }

  Future<void> _playMedia() async {
    final m = media;
    if (m == null) return;
    if (m is VideoHandle && (m.controller?.value.isInitialized != true)) return;
    _applySpeed();
    try {
      await m.setVolume(0);
    } catch (_) {}
    _playWithFadeIn(m);
    _endedFired = false;
    notifyListeners();
  }

  Future<void> togglePlay() async {
    final m = media;
    if (m == null) return;
    if (_switchFadeActive) return; // 正在渐变切换中，忽略
    if (!m.playing) {
      _fade.stop();
      _pausingFade = false;
      try {
        await m.setVolume(0);
      } catch (_) {}
      _playWithFadeIn(m);
    } else if (_pausingFade) {
      // 正在淡出暂停，再次按下改为立即继续
      _fade.stop();
      _pausingFade = false;
      try {
        await m.setVolume(0);
      } catch (_) {}
      _playWithFadeIn(m);
    } else {
      _pausingFade = true;
      playing = false;
      _fade.setLastVol(settings.defaultVolume / 100);
      _fade.fade(m, 0, kFxOutMs, onDone: () async {
        _pausingFade = false;
        await m.pause();
        playing = false;
        notifyListeners();
      });
    }
    notifyListeners();
  }

  Future<void> _stopCurrent() async {
    _fade.stop();
    _pausingFade = false;
    _switchFadeActive = false;
    _switchFadeTarget = null;
    final m = media;
    if (m is AudioHandle) {
      await m.pause();
    } else if (m is VideoHandle) {
      await m.pause();
    }
    media = null;
    playing = false;
    _endedFired = false;
    notifyListeners();
  }

  Future<void> stopAll() async {
    await _stopCurrent();
    await videoHandle?.disposeHandle();
    videoHandle = null;
    current = -1;
    notifyListeners();
  }

  void showEmpty() {
    current = -1;
    media = null;
    playing = false;
    notifyListeners();
  }

  Future<void> seekTo(double sec) async {
    final m = media;
    if (m == null) return;
    final d = m.durationSec;
    var v = sec;
    if (d > 0) v = v.clamp(0, d);
    if (v < 0) v = 0;
    await m.seekSec(v);
    _endedFired = false;
    notifyListeners();
  }

  Future<void> seekBy(double delta) async {
    final m = media;
    if (m == null) return;
    final d = m.durationSec;
    var v = m.positionSec + delta;
    if (v < 0) v = 0;
    if (d > 0 && v > d) v = d;
    await m.seekSec(v);
    notifyListeners();
  }

  void setSeeking(bool v) => _seeking = v;

  Future<void> setVolumeValue(double v, {bool remember = false}) async {
    settings.defaultVolume = v.clamp(0, 100).round();
    final m = media ?? audioHandle;
    try {
      await m.setVolume(settings.defaultVolume / 100);
    } catch (_) {}
    _fade.setLastVol(settings.defaultVolume / 100);
    if (remember) await saveSettings();
    notifyListeners();
  }

  Future<void> setSpeed(double v) async {
    settings.defaultSpeed = v;
    _applySpeed();
    await saveSettings();
    notifyListeners();
  }

  void _applySpeed() {
    final v = settings.defaultSpeed;
    audioHandle.setSpeed(v).catchError((_) {});
    videoHandle?.setSpeed(v).catchError((_) {});
  }

  /* ============================================================
     播放模式：下一曲 / 上一曲
     ============================================================ */
  void _buildShuffleBag() {
    final n = queue.length;
    final idx = <int>[];
    for (var i = 0; i < n; i++) {
      if (i != current) idx.add(i);
    }
    // Fisher-Yates
    for (var i = idx.length - 1; i > 0; i--) {
      final j = math.Random().nextInt(i + 1);
      final tmp = idx[i];
      idx[i] = idx[j];
      idx[j] = tmp;
    }
    _shuffleBag = idx;
    _shuffleBagPos = 0;
  }

  Future<void> next() async {
    final n = queue.length;
    if (n == 0) return;
    final mode = settings.playMode;
    if (mode == PlayMode.shuffleSmart) {
      if (_shuffleBag == null ||
          (_shuffleBagPos ?? 0) >= (_shuffleBag?.length ?? 0)) {
        _buildShuffleBag();
      }
      final bag = _shuffleBag!;
      if (bag.isEmpty) return; // 单曲列表，无法随机下一页
      final idx = bag[_shuffleBagPos!];
      _shuffleBagPos = _shuffleBagPos! + 1;
      await loadMedia(idx);
      return;
    }
    if (mode == PlayMode.shuffle) {
      var ni = current;
      while (ni == current && n > 1) {
        ni = math.Random().nextInt(n);
      }
      await loadMedia(ni);
      return;
    }
    if (current < n - 1) {
      await loadMedia(current + 1);
      return;
    }
    if (mode == PlayMode.all) {
      await loadMedia(0);
      return;
    }
    showToast('队列已播放完毕');
    await media?.pause();
    playing = false;
    notifyListeners();
  }

  Future<void> prev() async {
    if (queue.isEmpty) return;
    // 若已播放超过 3 秒则回到开头
    if (current >= 0 && media != null && media!.positionSec > 3) {
      await media!.seekSec(0);
      return;
    }
    await loadMedia(current > 0 ? current - 1 : queue.length - 1);
  }

  void _resetShuffleBag() {
    _shuffleBag = null;
    _shuffleBagPos = null;
  }

  Future<void> setPlayMode(PlayMode m) async {
    settings.playMode = m;
    await saveSettings();
    if (m == PlayMode.shuffleSmart) _resetShuffleBag();
    // 同步播放器循环模式，使自动续播行为与新设置一致
    _applyAudioLoopMode();
    showToast('播放模式：${m.label}');
    notifyListeners();
  }

  /* ============================================================
     时钟 tick：进度 / 断点续播 / 歌词 / 播放结束
     ============================================================ */
  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      _tick();
    });
  }

  void _tick() {
    final m = media;
    if (m == null) return;
    final pos = m.positionSec;
    final dur = m.durationSec;
    if (!_seeking) {
      final wasPlaying = playing;
      playing = m.playing;
      // 断点续播：节流保存进度
      if (settings.rememberProgress) {
        final item = currentItem;
        if (item != null && pos.isFinite && pos > 0) {
          _progressTimer?.cancel();
          _progressTimer = Timer(const Duration(milliseconds: 1500), () {
            _saveProgress(item.path, pos);
          });
        }
      }
      if (dur > 0 && pos >= dur - 0.25 && !_endedFired) {
        if (wasPlaying && !m.playing) {
          _onEnded();
        } else if (wasPlaying) {
          _onEnded();
        }
      }
    }
    // 歌词高亮（逐字填充进度由歌词视图自己的帧回调计算）
    if (lyricLines.isNotEmpty) {
      _updateLyrics(pos);
    }
    notifyListeners();
  }

  Future<void> _onEnded() async {
    _endedFired = true;
    // 音频：续播 / 单曲循环 / 列表循环全部由 just_audio 自己按 LoopMode 完成
    // （这样锁屏与 App 内的切歌走同一条路径，不会重复跳曲）；
    // 队列中的下标变化由 _bindPlayerIndex 统一同步回 UI。
    if (media is AudioHandle) return;
    final mode = settings.playMode;
    if (mode == PlayMode.one) {
      await media?.seekSec(0);
      await media?.play();
      _endedFired = false;
      playing = true;
      notifyListeners();
      return;
    }
    if (mode == PlayMode.off) {
      await media?.seekSec(0);
      playing = false;
      notifyListeners();
      return;
    }
    if (settings.autoNext) {
      await next();
    } else {
      await media?.seekSec(0);
      playing = false;
      notifyListeners();
    }
  }

  /* ============================================================
     歌词：装载 / 高亮 / 逐字填充
     ============================================================ */
  void setLyrics(String raw) {
    final parsed = parseLrc(raw);
    lyricLines
      ..clear()
      ..addAll(parsed);
    lyricActiveIdx = -1;
    if (lyricLines.isEmpty) {
      lyricCurPath = null;
      return;
    }
    groupLyrics(lyricLines);
    lyricCurPath = currentItem?.path;
    _updateLyrics(media?.positionSec ?? 0);
    notifyListeners();
  }

  void clearLyrics() {
    lyricLines.clear();
    lyricActiveIdx = -1;
    lyricCurPath = null;
    notifyListeners();
  }

  /// 手动导入歌词
  void importLyricsText(String content) {
    setLyrics(content);
    showToast('已导入歌词');
  }

  /// 自动查找歌词：先本地同名师，缺失且开启实验「自动寻找歌词」时联网兜底（LRCLIB）
  Future<void> autoLoadLyrics(MediaItem item) async {
    if (item.type != MediaType.audio) return;
    clearLyrics();
    // 会话内已联网抓到的歌词 → 直接应用
    final cached = _autoLyricCache[item.path];
    if (cached != null) {
      setLyrics(cached);
      return;
    }
    try {
      final content = await findSidecarLrc(item.path);
      if (content != null && lyricCurPath != item.path) {
        setLyrics(content);
        return;
      }
    } catch (_) {}
    // 本地歌词缺失 → 实验性「自动寻找歌词」联网兜底
    if (settings.expAutoLyrics && !_autoLyricsTried.contains(item.path)) {
      _autoLyricsTried.add(item.path);
      final dur = await _waitMediaDuration();
      final lrc = await fetchAutoLyrics(item.name, dur, log: debugPrint);
      if (lrc != null && lyricCurPath != item.path) {
        _autoLyricCache[item.path] = lrc;
        setLyrics(lrc);
        showToast('已联网获取歌词');
      }
    }
  }

  /// 等待当前媒体时长就绪（最多 4s），供自动歌词做严谨的时长匹配
  Future<double?> _waitMediaDuration() async {
    final m = media;
    if (m == null) return null;
    if (m.hasDuration && m.durationSec > 1) return m.durationSec;
    for (var i = 0; i < 16; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
      final mm = media;
      if (mm != null && mm.hasDuration && mm.durationSec > 1) return mm.durationSec;
    }
    return media?.durationSec;
  }

  /// 「显示歌词」主开关的实际效果
  Future<void> applyLyricsVisibility() async {
    if (settings.lyricsEnabled) {
      final it = currentItem;
      if (it != null && it.type == MediaType.audio) await autoLoadLyrics(it);
    } else {
      clearLyrics();
    }
  }

  void _updateLyrics(double time) {
    if (lyricLines.isEmpty) return;
    var idx = 0;
    for (var i = 0; i < lyricLines.length; i++) {
      if (time >= lyricLines[i].t) {
        idx = i;
      } else {
        break;
      }
    }
    final lead = lyricLines[idx].group;
    final changed = lead != lyricActiveIdx;
    lyricActiveIdx = lead;
    if (changed) notifyListeners();
  }

  /* ============================================================
     图片查看器状态
     ============================================================ */
  void resetImgState() {
    imgZoom = 1;
    imgRot = 0;
    imgFitActive = true;
    imgLeftPct = 50;
    imgTopPct = 50;
    notifyListeners();
  }

  void setImageNaturalSize(int w, int h) {
    if (w == imgNatW && h == imgNatH) return;
    imgNatW = w;
    imgNatH = h;
    notifyListeners();
  }

  void setStageSize(double w, double h) {
    if ((w - stageW).abs() < 0.5 && (h - stageH).abs() < 0.5) return;
    stageW = w;
    stageH = h;
    notifyListeners();
  }

  /// contain 适配比例
  double get containScale {
    if (imgNatW <= 0 || imgNatH <= 0 || stageW <= 0 || stageH <= 0) return 1;
    return math.min(stageW / imgNatW, stageH / imgNatH);
  }

  /// 图片渲染基准尺寸（布局尺寸，不含 scale 变换）—— 对应 clientWidth/clientHeight
  double get imgDispW {
    if (settings.imgFit == ImgFit.fill) return stageW;
    final base = imgFitActive ? containScale : 1.0;
    return imgNatW * base;
  }

  double get imgDispH {
    if (settings.imgFit == ImgFit.fill) return stageH;
    final base = imgFitActive ? containScale : 1.0;
    return imgNatH * base;
  }

  /// 有效缩放（fitActive 且 zoom<=1 时不额外缩放）—— 对应 vz
  double get imgVz => (imgFitActive && imgZoom <= 1) ? 1.0 : imgZoom;

  void zoomTo(double z) {
    imgFitActive = false;
    imgZoom = math.min(8, math.max(0.05, (z * 100).round() / 100));
    notifyListeners();
  }

  void zoomToSmooth(int dir) => zoomTo(imgZoom + dir * 0.15);

  void fitToContain() {
    imgFitActive = true;
    imgZoom = 1;
    imgLeftPct = 50;
    imgTopPct = 50;
    notifyListeners();
  }

  void rotateImg() {
    imgRot = (imgRot + 90) % 360;
    imgFitActive = false;
    notifyListeners();
    if (settings.showHints) showToast('已旋转 $imgRot°');
  }

  /// 拖动平移（把像素位移换算成百分位偏移）—— 对应 mousemove 平移
  void panImageBy(double dxPx, double dyPx) {
    final w = imgDispW <= 0 ? 1 : imgDispW;
    final h = imgDispH <= 0 ? 1 : imgDispH;
    imgLeftPct += dxPx / w * 100;
    imgTopPct += dyPx / h * 100;
    imgFitActive = false;
    notifyListeners();
  }

  /// 鹰眼图几何 —— 对应 mapGeom()
  ({double dw, double dh, double rx, double ry, double wR, double hR, double nx, double ny})
      mapGeom() {
    // 注意：imgNatW / imgDispW / imgNatH / imgDispH 都是 int，三元里的兜底值必须写 1.0，
    // 否则整个表达式推成 num，导致 dw/dh 与记录类型声明的 double 不匹配
    final double natW = imgNatW <= 0 ? 1.0 : imgNatW.toDouble();
    final double natH = imgNatH <= 0 ? 1.0 : imgNatH.toDouble();
    // 缩略图逻辑画布尺寸（对应 canvas 200x120）
    const cw = 200.0, ch = 120.0;
    final double s = math.min(cw / natW, ch / natH);
    final double dw = natW * s, dh = natH * s;
    final double rx = (cw - dw) / 2, ry = (ch - dh) / 2;
    final double dispW = imgDispW <= 0 ? natW : imgDispW.toDouble();
    final double dispH = imgDispH <= 0 ? natH : imgDispH.toDouble();
    final double vz = imgVz;
    final double vw = dispW * vz, vh = dispH * vz;
    final sw = stageW <= 0 ? cw : stageW;
    final sh = stageH <= 0 ? ch : stageH;
    final wR = math.min(1.0, sw / (vw <= 0 ? 1.0 : vw));
    final hR = math.min(1.0, sh / (vh <= 0 ? 1.0 : vh));
    var nx = (sw / 2 - (imgLeftPct / 100) * sw) / (vw <= 0 ? 1.0 : vw) + 0.5;
    var ny = (sh / 2 - (imgTopPct / 100) * sh) / (vh <= 0 ? 1.0 : vh) + 0.5;
    nx = nx.clamp(0.0, 1.0);
    ny = ny.clamp(0.0, 1.0);
    return (dw: dw, dh: dh, rx: rx, ry: ry, wR: wR, hR: hR, nx: nx, ny: ny);
  }

  /// 鹰眼图交互：点击/拖动视野框，主图视野跟着移动 —— 对应 setImgViewportFromMap()
  void setImgViewportFromMap(double px, double py) {
    if (imgNatW <= 0) return;
    const cw = 200.0, ch = 120.0;
    final natW = imgNatW.toDouble(), natH = imgNatH.toDouble();
    final s = math.min(cw / natW, ch / natH);
    final dw = natW * s, dh = natH * s;
    final rx = (cw - dw) / 2, ry = (ch - dh) / 2;
    var nx = (px - rx) / dw;
    var ny = (py - ry) / dh;
    final dispW = imgDispW <= 0 ? natW : imgDispW;
    final dispH = imgDispH <= 0 ? natH : imgDispH;
    final vz = imgVz;
    final vw = dispW * vz, vh = dispH * vz;
    final sw = stageW; // 舞台尺寸
    final sh = stageH;
    if (sw <= 0 || sh <= 0) return;
    final wR = math.min(1.0, sw / (vw <= 0 ? 1.0 : vw));
    final hR = math.min(1.0, sh / (vh <= 0 ? 1.0 : vh));
    nx = wR < 1 ? nx.clamp(wR / 2, 1 - wR / 2) : 0.5;
    ny = hR < 1 ? ny.clamp(hR / 2, 1 - hR / 2) : 0.5;
    imgLeftPct = 50 + (vw / 2 - nx * vw) / sw * 100;
    imgTopPct = 50 + (vh / 2 - ny * vh) / sh * 100;
    imgFitActive = false;
    notifyListeners();
  }

  /* ============================================================
     打开文件（供 UI 调用）
     ============================================================ */
  Future<void> addLocalPaths(List<String> paths, {Map<String, String>? names}) async {
    final files = <MediaItem>[];
    var invalid = 0;
    for (final path in paths) {
      try {
        final st = await FileSystemEntity.type(path);
        if (st == FileSystemEntityType.directory) {
          final list = await _listDir(path, settings.recursiveFolder);
          if (list.isEmpty) {
            showToast(lastScanError != null
                ? '无法读取文件夹：$lastScanError'
                : '文件夹中没有识别到媒体文件');
          } else {
            await addToQueue(list);
          }
        } else {
          final hint = names?[path];
          var it = MediaItem.fromPath(path, fallbackName: hint);
          if (it == null) {
            // 扩展名不可用（SAF 把名字换成了标题）：按内容嗅探兜底
            final kind = await MediaProbeService.instance.kind(path);
            if (kind != null) {
              final base = path.split('/').last;
              it = MediaItem(
                path: path,
                name: (hint != null && hint.isNotEmpty) ? hint : base,
                type: kind,
              );
            }
          }
          if (it == null) {
            invalid++;
          } else {
            files.add(it);
          }
        }
      } catch (_) {
        invalid++;
      }
    }
    if (files.isNotEmpty) await addToQueue(files);
    if (invalid > 0) {
      showToast('无法播放：$invalid 个文件是二进制/不支持的格式，未加入队列');
    }
  }

  /// HEAD 探测远端媒体类型：用于路径里没带扩展名的流媒体直链
  Future<MediaType?> _probeUrlType(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    if (!(uri.isScheme('http') || uri.isScheme('https'))) return null;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.headUrl(uri);
      req.followRedirects = false;
      req.headers.set(HttpHeaders.userAgentHeader, kHttpUserAgent);
      final res = await req.close();
      await res.drain<void>();
      if (res.statusCode < 200 || res.statusCode >= 400) return null;
      final ct = res.headers.contentType?.mimeType ?? '';
      if (ct.startsWith('audio/')) return MediaType.audio;
      if (ct.startsWith('video/')) return MediaType.video;
      if (ct.startsWith('image/')) return MediaType.image;
    } catch (_) {
    } finally {
      client.close(force: true);
    }
    return null;
  }

  /// 最近一次目录扫描的失败原因（null 表示未失败）
  String? lastScanError;

  Future<List<MediaItem>> _listDir(String dir, bool recursive) async {
    final out = <MediaItem>[];
    lastScanError = null;
    try {
      final d = Directory(dir);
      if (!await d.exists()) {
        lastScanError = '路径不存在';
        return out;
      }
      await for (final e in d.list(recursive: recursive, followLinks: false)) {
        if (e is File) {
          final it = MediaItem.fromPath(e.path);
          if (it != null) out.add(it);
        }
      }
    } catch (e) {
      // 不再静默吞掉：多半是缺少存储权限
      lastScanError = '$e';
    }
    out.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    return out;
  }

  Future<void> addUrl(String url) async {
    var it = MediaItem.fromUrl(url);
    // 很多流媒体直链不带扩展名（.../song?id=123），按 Content-Type 兜底判定
    if (it == null) {
      final kind = await _probeUrlType(url);
      final uri = Uri.tryParse(url);
      if (kind != null && uri != null) {
        final seg = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
        it = MediaItem(
          path: url,
          name: seg.isNotEmpty ? Uri.decodeComponent(seg) : url,
          type: kind,
          url: true,
        );
      }
    }
    if (it == null) {
      showToast('不支持该 URL 的媒体格式');
      return;
    }
    await addToQueue([it]);
  }
}