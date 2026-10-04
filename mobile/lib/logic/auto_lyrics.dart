import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:fast_gbk/fast_gbk.dart';
import 'package:path/path.dart' as p;

/// 网络歌词白名单清洗 —— 对应 sanitizeAutoLyrics()
/// 即使 API 被投毒/篡改，也只放行结构合法的纯 LRC。
String? sanitizeAutoLyrics(String? lrc) {
  if (lrc is! String) return null;
  if (lrc.length > 200000) return null; // 体积上限
  // 去控制字符（保留 \n \t）
  final clean = lrc.replaceAll(
      RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]'), '');
  final lines = clean.split(RegExp(r'\r?\n')).where((l) => l.isNotEmpty).toList();
  if (lines.isEmpty || lines.length > 3000) return null;
  // 至少 40% 行以 [m:ss(.xx)] 时间戳开头，否则视为垃圾/恶意内容
  final tsRe = RegExp(r'^\s*\[(\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?)\]');
  final hit = lines.where((l) => tsRe.hasMatch(l)).length;
  final ratio = hit / lines.length;
  if (ratio < 0.4) return null;
  return clean;
}

/// 解析文件名 → {artist, track}（支持 "歌手 - 歌曲名.xxx"）—— 对应 parseTrackName()
({String artist, String track}) parseTrackName(String? name) {
  final base = (name ?? '').replaceFirst(RegExp(r'\.[^.]+$'), '');
  final parts = base.split(RegExp(r'[－\u2013\u2014\-]'));
  if (parts.length >= 2) {
    return (
      artist: parts[0].trim(),
      track: parts.sublist(1).join('-').trim(),
    );
  }
  return (artist: '', track: base.trim());
}

/// 歌词版本与媒体时长的可接受偏差(秒)
const int lrcDurationTolerance = 5;

/// 常见简繁字形对照表，每项为「简体字形 + 繁体字形」，用于粗判歌词正文的简繁倾向。
/// LRCLIB 上很多条目标题是简体、正文却是上传者填的繁体，只靠时长选候选会随机撞到繁体。
const List<String> _zhVariantPairs = <String>[
  '爱愛', '听聽', '说說', '们們', '这這', '个個', '时時', '间間',
  '么麼', '开開', '关關', '无無', '为為', '与與', '从從', '来來',
  '会會', '后後', '里裡', '过過', '还還', '进進', '让讓', '见見',
  '觉覺', '对對', '头頭', '学學', '习習', '声聲', '单單', '终終',
  '记記', '忆憶', '释釋', '怀懷', '忧憂', '伤傷', '泪淚', '温溫',
  '风風', '云雲', '转轉', '万萬', '长長', '门門', '问問', '体體',
  '验驗', '双雙', '证證', '认認', '识識', '语語', '谢謝', '该該',
  '应應', '总總', '结結', '纯純', '实實', '样樣', '种種', '类類',
  '边邊', '观觀', '现現', '点點', '热熱', '击擊', '报報', '纸紙',
  '错錯', '药藥', '气氣', '车車', '东東', '马馬', '鸟鳥', '鱼魚',
  '梦夢', '恋戀', '桥橋', '湾灣', '阳陽', '阴陰', '归歸', '遗遺',
  '郁鬱', '缠纏', '绵綿', '尽盡', '将將', '几幾', '处處', '词詞',
  '诗詩', '谁誰', '谜謎', '旷曠', '搁擱', '浅淺', '乐樂', '岁歲',
  '旧舊', '缘緣', '尘塵', '绕繞', '雾霧', '飘飄', '离離', '断斷',
  '闹鬧', '静靜', '独獨', '锁鎖', '唤喚', '拥擁', '择擇', '赢贏',
  '输輸', '飞飛', '烦煩', '恼惱', '织織', '洒灑',
];

/// 简繁倾向分：繁体字形出现次数 − 简体字形出现次数（>0 偏繁体，<0 偏简体）
int zhTradScore(String text) {
  var score = 0;
  for (final pair in _zhVariantPairs) {
    score += _countOf(text, pair[1]) - _countOf(text, pair[0]);
  }
  return score;
}

int _countOf(String text, String ch) => text.split(ch).length - 1;

/// 联网请求统一使用的 User-Agent（LRCLIB 等公共服务要求声明来源）
const String kHttpUserAgent = 'Sylphplay/1.0 (https://ruanftrix.cn)';

/// 从 LRCLIB 拉取 LRC —— 对应 fetchAutoLyrics()
/// duration 用于与媒体时长匹配校验，走不通再退化为纯文字匹配。
Future<String?> fetchAutoLyrics(String? itemName, double? targetDur,
    {void Function(String)? log}) async {
  final parsed = parseTrackName(itemName);
  if (parsed.track.isEmpty) return null;
  final durSec = (targetDur != null && targetDur.isFinite && targetDur > 1)
      ? targetDur.round()
      : null;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  try {
    // 1) 精确匹配：服务端会同时校验 歌手/歌名/时长 时间窗
    final got = await _fetchJson(
      client,
      Uri.https('lrclib.net', '/api/get', {
        'track_name': parsed.track,
        if (parsed.artist.isNotEmpty) 'artist_name': parsed.artist,
        if (durSec != null) 'duration': '$durSec',
      }),
      log: log,
    );
    final gotLrc = (got is Map && got['syncedLyrics'] is String)
        ? sanitizeAutoLyrics(got['syncedLyrics'] as String)
        : null;
    // /api/get 命中的条目正文可能是繁体（标题简体、正文由上传者填繁体），
    // 这种情况一样去搜候选，优先挑简体版本。
    if (gotLrc == null || zhTradScore(gotLrc) > 0) {
      // 2) 候选搜索：多条候选，本地按 简繁倾向 + 时长接近度 排序
      final list = await _fetchJson(
        client,
        Uri.https('lrclib.net', '/api/search', {
          'track_name': parsed.track,
          if (parsed.artist.isNotEmpty) 'artist_name': parsed.artist,
        }),
        log: log,
      );
      if (list is List) {
        final cands = list
            .whereType<Map>()
            .where((x) => x['syncedLyrics'] is String)
            .map((x) => x.cast<String, dynamic>())
            .toList();
        // 简体优先，简繁相当再比时长接近度；时长容差在下方选取时仍会过滤，
        // 因此超出容差的简体候选不会挤掉容差内的候选。
        cands.sort((a, b) {
          final ta = zhTradScore(a['syncedLyrics'] as String);
          final tb = zhTradScore(b['syncedLyrics'] as String);
          if (ta != tb) return ta.compareTo(tb);
          return _durationDelta(a, durSec).compareTo(_durationDelta(b, durSec));
        });
        final pick = cands.firstWhere(
          (x) =>
              durSec == null || _durationDelta(x, durSec) <= lrcDurationTolerance,
          orElse: () => <String, dynamic>{},
        );
        if (pick.isNotEmpty) {
          final lrc = sanitizeAutoLyrics(pick['syncedLyrics'] as String);
          // 候选确实更偏简体才替换，否则保留 /api/get 的结果
          if (lrc != null &&
              (gotLrc == null || zhTradScore(lrc) < zhTradScore(gotLrc))) {
            return lrc;
          }
        }
      }
    }
    return gotLrc;
  } catch (e) {
    log?.call('[自动歌词] 异常 $e');
    return null;
  } finally {
    client.close(force: true);
  }
}

/// 候选与目标时长的偏差(秒)；候选没有时长信息时按 0 计
double _durationDelta(Map<String, dynamic> x, int? durSec) =>
    ((x['duration'] is num ? x['duration'] as num : 0) - (durSec ?? 0))
        .abs()
        .toDouble();

/// 拉 JSON：不带 Cookie、拒绝重定向（防 hosts 篡改后被改道）、体积上限 1MB
Future<dynamic> _fetchJson(HttpClient client, Uri uri,
    {void Function(String)? log}) async {
  try {
    final req = await client.getUrl(uri);
    req.followRedirects = false;
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    // LRCLIB 明确要求带 User-Agent，缺失时会被拒（这是自动歌词一直失败的原因）
    req.headers.set(HttpHeaders.userAgentHeader, kHttpUserAgent);
    // 不带 Cookie：HttpClient 默认不发送 Cookie
    final res = await req.close();
    if (res.statusCode < 200 || res.statusCode >= 300) {
      log?.call('[自动歌词] HTTP ${res.statusCode} $uri');
      return null;
    }
    final len = res.contentLength;
    if (len > 1000000) {
      log?.call('[自动歌词] 响应超过 1MB，拒绝');
      return null;
    }
    final body = await res.transform(utf8.decoder).join();
    if (body.length > 1000000) return null;
    return jsonDecode(body);
  } catch (e) {
    log?.call('[自动歌词] fetch 失败 $uri $e');
    return null;
  }
}

/// 查找同名 sidecar 歌词文件（音频同目录下的 .lrc）—— 对应主进程 findSidecarLrc
Future<String?> findSidecarLrc(String audioPath) async {
  try {
    if (audioPath.startsWith('http://') || audioPath.startsWith('https://')) {
      return null;
    }
    final dir = p.dirname(audioPath);
    final base = p.basenameWithoutExtension(audioPath);
    final candidates = [
      p.join(dir, '$base.lrc'),
      p.join(dir, '$base.LRC'),
      p.join(dir, '$base.Lrc'),
      p.join(dir, '$base.Lyric.lrc'),
    ];
    for (final c in candidates) {
      final f = File(c);
      if (await f.exists()) {
        try {
          return decodeLyricBytes(await f.readAsBytes());
        } catch (_) {
          return null;
        }
      }
    }
  } catch (_) {}
  return null;
}

/// 歌词字节解码 —— 手动导入与同名 sidecar 两条路径统一走这里。
/// 顺序：BOM → 严格 UTF-8 → GBK（酷我等下载源常见）→ 宽松 UTF-8 保底。
/// 此前 sidecar 路径误用 latin1 兜底，会把 GBK 中文逐字节解成乱码
/// （外观近似阿拉伯文），与本文件外的 GBK 解码行为不一致。
String decodeLyricBytes(List<int> bytes) {
  if (bytes.isEmpty) return '';
  // 1) 带 BOM：直接按 BOM 指明的编码解，避免被误判
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return _stripBom(utf8.decode(bytes.sublist(3), allowMalformed: true));
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return _stripBom(_decodeUtf16(bytes.sublist(2), littleEndian: true));
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return _stripBom(_decodeUtf16(bytes.sublist(2), littleEndian: false));
  }
  // 2) 严格 UTF-8（失败会抛 FormatException）
  try {
    return _stripBom(utf8.decode(bytes));
  } on FormatException {
    // 非 UTF-8，继续尝试中文编码
  }
  // 3) GBK
  try {
    return _stripBom(gbk.decode(bytes));
  } catch (_) {
    // 非 GBK，落到保底
  }
  // 4) 宽松 UTF-8：绝不抛错，保证整份歌词不被丢弃
  return _stripBom(utf8.decode(bytes, allowMalformed: true));
}

/// 去掉解码后残留的 BOM 字符
String _stripBom(String s) =>
    s.isNotEmpty && s.codeUnitAt(0) == 0xFEFF ? s.substring(1) : s;

/// 手工解码 UTF-16（按 UTF-16 码元拼装，Dart 字符串本身即 UTF-16）
String _decodeUtf16(List<int> b, {required bool littleEndian}) {
  final units = <int>[];
  for (var i = 0; i + 1 < b.length; i += 2) {
    units.add(littleEndian ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1]);
  }
  return String.fromCharCodes(units);
}

/// 供「等待媒体时长就绪」用：把 NaN/0 归一为 null
double? normalizeDuration(double? d) {
  if (d == null || !d.isFinite || d <= 0) return null;
  return d;
}

/// 把秒转成 LRCLIB duration 参数（整数、非负）
int? durationParam(double? d) {
  final n = normalizeDuration(d);
  if (n == null || n <= 1) return null;
  return math.max(1, n.round());
}