import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../logic/lrc.dart';
import '../logic/visualizer.dart';
import '../models/media_item.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// 音乐播放器视图 —— 对应 #view-audio（封面 / 频谱 / 标题 / 元信息 / 歌词）
///
/// 桌面版：有歌词时隐藏封面与频谱，中间区域换成歌词（高度 = 行数 × 37）。
/// 歌词当前行高亮居中，同组次级行（译文）淡色小字；实验性逐字渐变填充用
/// clip-path 从左向右揭示。频谱：无 analyser 时留空，绝不伪造波形。
class AudioStageView extends StatefulWidget {
  const AudioStageView({super.key});

  @override
  State<AudioStageView> createState() => _AudioStageViewState();
}

class _AudioStageViewState extends State<AudioStageView> {
  final ScrollController _scroll = ScrollController();
  StreamSubscription<List<double>>? _vizSub;
  List<double> _bands = const <double>[];
  int _lastActive = -1;

  @override
  void initState() {
    super.initState();
    _vizSub = VisualizerService.instance.bands.listen((b) {
      if (!mounted) return;
      setState(() => _bands = b);
    });
    VisualizerService.instance.start();
  }

  @override
  void dispose() {
    _vizSub?.cancel();
    VisualizerService.instance.stop();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToActive() {
    final st = context.read<AppState>();
    final idx = st.lyricActiveIdx;
    if (idx < 0 || idx == _lastActive) return;
    _lastActive = idx;
    if (!_scroll.hasClients) return;
    final n = st.settings.lyricsLines.clamp(3, 12);
    final viewport = n * 37.0;
    final target = (idx * 37.0 - viewport / 2 + 18.5)
        .clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final c = SylphColorsScope.of(context);
    final item = st.currentItem;
    if (item == null) return const SizedBox.shrink();

    if (st.lyricActiveIdx >= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToActive();
      });
    }

    final mq = MediaQuery.of(context).size;
    final showLyrics = st.showLyricsView;
    final dur = st.durationSec;
    final meta = '${TypeMeta.of(MediaType.audio).label}'
        '${dur > 0 ? ' · ${fmtTime(dur)}' : ''}';

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: showLyrics
              ? [
                  // 有歌词：仅标题 + 元信息 + 歌词
                  _Title(item.name),
                  const SizedBox(height: 4),
                  _Meta(meta),
                  const SizedBox(height: 10),
                  _LyricsBox(
                    lines: st.lyricLines,
                    activeIdx: st.lyricActiveIdx,
                    linesCount: st.settings.lyricsLines.clamp(3, 12),
                    fill: st.settings.expLyricsFill,
                    width: math.min(860.0, mq.width * 0.94),
                    controller: _scroll,
                    colors: c,
                  ),
                ]
              : [
                  // 无歌词：封面 + 频谱 + 标题 + 元信息
                  _Cover(colors: c),
                  const SizedBox(height: 18),
                  _Viz(
                    bands: st.settings.vizEnabled ? _bands : const [],
                    width: math.min(760.0, mq.width * 0.92),
                    colors: c,
                  ),
                  const SizedBox(height: 14),
                  _Title(item.name),
                  const SizedBox(height: 4),
                  _Meta(meta),
                ],
        ),
      ),
    );
  }
}

class _Title extends StatelessWidget {
  final String text;
  const _Title(this.text);
  @override
  Widget build(BuildContext context) {
    // 与桌面版一致：19px 粗体
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Text(
        text,
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  final String text;
  const _Meta(this.text);
  @override
  Widget build(BuildContext context) {
    final c = SylphColorsScope.of(context);
    return Text(text, style: TextStyle(color: c.textDim, fontSize: 13.5));
  }
}

/// 封面 —— 对应 .audio-art（220×220，圆角 18，2px 边框）
class _Cover extends StatelessWidget {
  final SylphColors colors;
  const _Cover({required this.colors});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      height: 220,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.border, width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(60),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.asset('assets/icon.png', fit: BoxFit.cover),
    );
  }
}

/// 频谱 —— 对应 #viz（64 根柱，accent-2 → accent 渐变，基线留 45%）
class _Viz extends StatelessWidget {
  final List<double> bands;
  final double width;
  final SylphColors colors;
  const _Viz({required this.bands, required this.width, required this.colors});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: 140,
      child: CustomPaint(
        painter: _VizPainter(bands: bands, accent: colors.accent, accent2: colors.accent2),
      ),
    );
  }
}

class _VizPainter extends CustomPainter {
  final List<double> bands;
  final Color accent;
  final Color accent2;
  _VizPainter({required this.bands, required this.accent, required this.accent2});

  @override
  void paint(Canvas canvas, Size size) {
    // 无 analyser / 无数据 → 空频谱（对应 drawEmptyViz）
    if (bands.isEmpty || size.width <= 0) return;
    const bars = 64;
    final W = size.width;
    final H = size.height;
    final g = H * 0.45; // 对应桌面版 g=72 / H=160
    final bw = (W - 8) / bars;
    for (var i = 0; i < bars; i++) {
      final v = i < bands.length ? bands[i].clamp(0.0, 1.0) : 0.0;
      final bh = math.max(2.0, v * (H - g));
      final x = 4 + i * bw;
      final rect = Rect.fromLTWH(x, H - g - bh, math.max(1.0, bw - 3), bh);
      final rr = RRect.fromRectAndRadius(rect, const Radius.circular(3));
      final paint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [accent2, accent],
        ).createShader(rect);
      canvas.drawRRect(rr, paint);
    }
  }

  @override
  bool shouldRepaint(_VizPainter old) =>
      old.accent != accent || old.accent2 != accent2 || !_sameBands(old.bands, bands);

  static bool _sameBands(List<double> a, List<double> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// 歌词列表 —— 对应 .lyrics / .lyrics-scroll / .lyrics-line
class _LyricsBox extends StatefulWidget {
  final List<LyricLine> lines;
  final int activeIdx;
  final int linesCount;
  final bool fill;
  final double width;
  final ScrollController controller;
  final SylphColors colors;
  const _LyricsBox({
    required this.lines,
    required this.activeIdx,
    required this.linesCount,
    required this.fill,
    required this.width,
    required this.controller,
    required this.colors,
  });

  @override
  State<_LyricsBox> createState() => _LyricsBoxState();
}

class _LyricsBoxState extends State<_LyricsBox>
    with SingleTickerProviderStateMixin {
  /// 逐字填充进度 0..1。
  ///
  /// 关键：它由一条**帧回调**驱动，而不是跟着 AppState 的 250ms 计时器走。
  /// 后者只有 4 步/秒，在 60/120Hz 屏幕上肉眼就是「卡」；其它动画走 vsync
  /// 所以顺滑，这正是问题所在。
  final ValueNotifier<double> _fill = ValueNotifier<double>(0);
  late final _ticker = createTicker(_onFrame);

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(_LyricsBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _fill.dispose();
    super.dispose();
  }

  /// 只有「开启填充 + 有当前行」时才跑帧回调，其余情况停掉，别白烧 CPU
  void _syncTicker() {
    final want = widget.fill && widget.activeIdx >= 0;
    if (want) {
      if (!_ticker.isActive) _ticker.start();
    } else if (_ticker.isActive) {
      _ticker.stop();
      _fill.value = 0;
    }
  }

  void _onFrame(Duration _) {
    if (!mounted) return;
    final idx = widget.activeIdx;
    if (idx < 0 || idx >= widget.lines.length) return;
    final m = context.read<AppState>().media;
    if (m == null) return;
    final line = widget.lines[idx];
    // 与 AppState._updateLyrics 一致：下一行取时间轴上紧随其后的那一行
    LyricLine? nxt;
    for (final l in widget.lines) {
      if (l.t > line.t) {
        nxt = l;
        break;
      }
    }
    _fill.value =
        lineFraction(line, nxt, m.positionSec, m.durationSec).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    // 一行 ≈ 37px；容器高度 = 行数 × 37
    return SizedBox(
      width: widget.width,
      height: widget.linesCount * 37.0,
      child: ListView.builder(
        controller: widget.controller,
        itemExtent: 37,
        padding: EdgeInsets.zero,
        itemCount: widget.lines.length,
        itemBuilder: (ctx, i) => _buildLine(i),
      ),
    );
  }

  Widget _buildLine(int i) {
    final colors = widget.colors;
    final line = widget.lines[i];
    final text = line.text;
    final group = line.group;
    final active = i == widget.activeIdx;
    final sub = !active && group == widget.activeIdx;
    final fontSize = sub ? 15.0 : 17.0;
    final weight = active ? FontWeight.w700 : FontWeight.w400;

    // 实验性逐字填充：底字（淡）+ 高亮覆盖层（按帧裁剪，从左向右揭示）
    if (widget.fill && active) {
      final baseStyle = TextStyle(
        color: colors.textFaint,
        fontSize: 17,
        fontWeight: weight,
        height: 2.1,
      );
      final fillStyle = baseStyle.copyWith(color: colors.accent);
      return Center(
        child: Transform.scale(
          scale: 1.05,
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              Text(text, style: baseStyle),
              ValueListenableBuilder<double>(
                valueListenable: _fill,
                child: Text(text, style: fillStyle),
                builder: (_, ratio, child) =>
                    ClipRect(clipper: _FillClipper(ratio), child: child),
              ),
            ],
          ),
        ),
      );
    }

    final style = TextStyle(
      color: active ? colors.accent : colors.textFaint,
      fontSize: fontSize,
      fontWeight: weight,
      height: 2.1,
    );
    final content = FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(text, style: style, maxLines: 1),
    );
    if (active) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Transform.scale(scale: 1.05, child: content),
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: content,
      ),
    );
  }
}

/// 按比例从左向右裁剪 —— 只触发重绘，不引起子级重新布局
/// （原来的 Align(widthFactor:) 改的是布局属性，每帧都要走一次 layout）
class _FillClipper extends CustomClipper<Rect> {
  final double ratio;
  const _FillClipper(this.ratio);

  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width * ratio, size.height);

  @override
  bool shouldReclip(_FillClipper oldClipper) => oldClipper.ratio != ratio;
}