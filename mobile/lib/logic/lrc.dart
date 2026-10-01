/// LRC 歌词解析与逐字填充模型 —— 与桌面版 renderer.js 的 Lyrics / lineFraction / lineBreakpoints 完全同源
library;

/// 每字演唱估算秒数（填充节奏基准）
const double lyricPerChar = 0.5;

class LyricWord {
  final double t;
  final String text;
  const LyricWord(this.t, this.text);
}

class LyricLine {
  /// 起始秒
  final double t;
  final String text;

  /// 卡拉OK逐词时间戳（普通行为 null）
  final List<LyricWord>? words;

  /// 双语/KaraOK 配对组号（同起始时间 ±40ms 归为一组，取组内首个下标）
  int group = 0;

  LyricLine({required this.t, required this.text, this.words});
}

/// 时间戳正则：[mm:ss.xx] / [mm:ss:xx]，捕获后面的文本（不含 '['）
final RegExp _tsRe = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]([^\[]*)');
final RegExp _tsTestRe = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:]\d+)?\]');

/// 解析 LRC 文本 —— 对应 Lyrics.parse()
///
/// 每行输出：
///  - 卡拉OK行（行内多个带文字的段）：整行只出一行干净拼接的 text，并附 words
///  - 普通行（仅一个带文字的段）：其之前的所有时间戳都指向同一段文字，各出一行
///  - 全空段（纯时间戳行）忽略
List<LyricLine> parseLrc(String? raw) {
  final out = <LyricLine>[];
  if (raw == null || raw.isEmpty) return out;
  final lines = raw.split(RegExp(r'\r?\n'));
  for (final line in lines) {
    if (!_tsTestRe.hasMatch(line)) continue;
    final segs = <LyricWord>[];
    for (final m in _tsRe.allMatches(line)) {
      final min = int.parse(m.group(1)!);
      final sec = int.parse(m.group(2)!);
      final fracStr = m.group(3);
      final frac = fracStr != null ? int.parse(fracStr) : 0;
      final t = min * 60 + sec + ((fracStr != null && frac > 0) ? frac / _pow10(fracStr.length) : 0);
      segs.add(LyricWord(t.toDouble(), m.group(4) ?? ''));
    }
    if (segs.isEmpty) continue;
    // 非空文本段：只统计真正带文字的段
    final nonEmpty = segs.where((s) => s.text.trim().isNotEmpty).toList();
    if (nonEmpty.length >= 2) {
      // 卡拉OK行
      final joined = segs.map((s) => s.text).join('').trim();
      out.add(LyricLine(
        t: segs[0].t,
        text: joined.isNotEmpty ? joined : segs[0].text,
        words: nonEmpty.map((s) => LyricWord(s.t, s.text)).toList(),
      ));
    } else if (nonEmpty.length == 1) {
      final text = nonEmpty[0].text;
      final idx = segs.indexOf(nonEmpty[0]);
      for (var k = 0; k <= idx; k++) {
        out.add(LyricLine(t: segs[k].t, text: text));
      }
    }
    // 全是空段 → 忽略
  }
  out.sort((a, b) => a.t.compareTo(b.t));
  return out;
}

double _pow10(int n) {
  var v = 1.0;
  for (var i = 0; i < n; i++) {
    v *= 10;
  }
  return v;
}

/// 双语/KaraOK 配对：开始时间相同(±40ms)的相邻行归为一组 —— 对应 Lyrics.set() 中 _g 计算
void groupLyrics(List<LyricLine> lines) {
  for (var i = 0; i < lines.length; i++) {
    if (i > 0 && (lines[i].t - lines[i - 1].t).abs() < 0.04) {
      lines[i].group = lines[i - 1].group;
    } else {
      lines[i].group = i;
    }
  }
}

double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

/// 计算单行歌词的填充进度(0~1) —— 对应 lineFraction()
///
///  - 卡拉OK：用每词真实时间戳分段，词与词之间线性推进
///  - 普通行：在 [行起点, min(行起点+按字数估算时长, 下一句起点)] 内线性推进；已唱到下一句则强制填满
double lineFraction(LyricLine line, LyricLine? nxt, double time, double mediaDuration) {
  final lt = line.t;
  final words = line.words;
  final chars = line.text.isNotEmpty
      ? line.text.length
      : (words != null && words.isNotEmpty
          ? words.fold<int>(0, (s, w) => s + w.text.length)
          : 1);
  final durLimit = (mediaDuration > 0 ? mediaDuration : 30) - lt;
  final dur = _maxD(0.4, _minD(chars * lyricPerChar, durLimit));
  if (words != null && words.isNotEmpty) {
    final ws = words;
    final total = ws.fold<int>(0, (s, w) => s + w.text.length);
    final totalF = total > 0 ? total : 1;
    var done = 0.0;
    for (var j = 0; j < ws.length; j++) {
      final wEnd = (j + 1 < ws.length) ? ws[j + 1].t : (nxt != null ? nxt.t : (lt + dur));
      if (time < ws[j].t) break;
      if (time < wEnd) {
        final f = _clamp01((time - ws[j].t) / _maxD(0.05, wEnd - ws[j].t));
        done += f * ws[j].text.length;
        break;
      }
      done += ws[j].text.length;
    }
    return _clamp01(done / totalF);
  }
  final p = (nxt != null && time >= nxt.t) ? 1.0 : (time - lt) / dur;
  return _clamp01(p);
}

/// 生成单行歌词的「分段折线模型」：[[音频秒, 填充分数], ...] —— 对应 lineBreakpoints()
List<List<double>> lineBreakpoints(LyricLine line, LyricLine? nxt, double mediaDuration) {
  final words = (line.words != null && line.words!.isNotEmpty) ? line.words! : null;
  final pts = <List<double>>[];
  if (words != null) {
    final lens = words.map((w) => w.text.length).toList();
    final total = lens.fold<int>(0, (s, n) => s + n);
    final totalF = total > 0 ? total : 1;
    final dur = _maxD(0.4, total * lyricPerChar);
    final lastEnd = nxt != null ? nxt.t : (line.t + dur);
    var done = 0;
    for (var j = 0; j < words.length; j++) {
      final wEnd = (j + 1 < words.length) ? words[j + 1].t : lastEnd;
      pts.add([words[j].t, done / totalF]);
      done += lens[j];
      pts.add([wEnd, done / totalF]);
    }
    return pts;
  }
  final chars = line.text.isNotEmpty ? line.text.length : 1;
  final durLimit = (mediaDuration > 0 ? mediaDuration : 30) - line.t;
  final dur = _maxD(0.4, _minD(chars * lyricPerChar, durLimit));
  final segEnd = nxt != null ? _minD(line.t + dur, nxt.t) : (line.t + dur);
  pts.add([line.t, 0]);
  pts.add([segEnd, _clamp01((segEnd - line.t) / dur)]);
  if (nxt != null) pts.add([_maxD(segEnd, nxt.t), 1]);
  return pts;
}

/// 按折线模型在任意音频秒求填充分数（供桌面歌词小窗式的锚点求值）
double evalBreakpoints(List<List<double>> pts, double t) {
  if (pts.isEmpty) return 0;
  if (t <= pts.first[0]) return pts.first[1];
  for (var i = 1; i < pts.length; i++) {
    final a = pts[i - 1], b = pts[i];
    if (t <= b[0]) {
      final span = b[0] - a[0];
      if (span <= 0) return b[1];
      final f = (t - a[0]) / span;
      return a[1] + (b[1] - a[1]) * f;
    }
  }
  return pts.last[1];
}

double _minD(double a, double b) => a < b ? a : b;
double _maxD(double a, double b) => a > b ? a : b;