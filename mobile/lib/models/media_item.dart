import 'package:path/path.dart' as p;

/// 媒体类型 —— 对应桌面版 main.js 的 MEDIA_EXT 分类
enum MediaType { image, video, audio }

/// 扩展名分类表（与 main.js MEDIA_EXT 完全一致）
class MediaExt {
  static const image = [
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'avif', 'jpg2', 'j2k',
    'jpf', 'ico', 'jfif'
  ];
  static const video = [
    'mp4', 'webm', 'mkv', 'mov', 'm4v', 'ogv', 'avi', 'mpg', 'mpeg',
    '3gp', '3g2', 'ts', 'm2ts'
  ];
  static const audio = [
    'mp3', 'wav', 'ogg', 'oga', 'opus', 'm4a', 'aac', 'flac', 'wma',
    'weba', 'amr', 'mid', 'midi'
  ];

  static List<String> get all => [...image, ...video, ...audio];

  static MediaType? classifyExt(String ext) {
    final e = ext.toLowerCase();
    if (image.contains(e)) return MediaType.image;
    if (video.contains(e)) return MediaType.video;
    if (audio.contains(e)) return MediaType.audio;
    return null;
  }
}

/// 队列条目 —— 对应桌面版 S.queue 元素 {path,name,type,size,url}
class MediaItem {
  final String path;
  final String name;
  final MediaType type;
  final int size;
  /// 是否为远程 URL 条目（url: true），影响是否走本地文件路径
  final bool url;
  /// 用户手动关联的 sidecar 歌词（LRC）绝对路径；null 表示未关联
  final String? lrcPath;

  const MediaItem({
    required this.path,
    required this.name,
    required this.type,
    this.size = 0,
    this.url = false,
    this.lrcPath,
  });

  MediaItem copyWith({String? path, String? name, MediaType? type, int? size, bool? url, String? lrcPath}) => MediaItem(
    path: path ?? this.path,
    name: name ?? this.name,
    type: type ?? this.type,
    size: size ?? this.size,
    url: url ?? this.url,
    lrcPath: lrcPath ?? this.lrcPath,
  );

  Map<String, dynamic> toJson() => {
        'path': path,
        'name': name,
        'type': type.name,
        'size': size,
        'url': url,
        if (lrcPath != null) 'lrcPath': lrcPath,
      };

  static MediaItem? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    final typeStr = raw['type'];
    if (path is! String || path.isEmpty) return null;
    final type = _typeFromName(typeStr is String ? typeStr : '');
    if (type == null) return null;
    return MediaItem(
      path: path,
      name: (raw['name'] is String) ? raw['name'] as String : p.basename(path),
      type: type,
      size: (raw['size'] is num) ? (raw['size'] as num).toInt() : 0,
      url: raw['url'] == true,
      lrcPath: raw['lrcPath'] is String ? raw['lrcPath'] as String : null,
    );
  }

  static MediaType? _typeFromName(String n) {
    for (final t in MediaType.values) {
      if (t.name == n) return t;
    }
    return null;
  }

  /// 由文件路径构造（本地文件）
  ///
  /// [fallbackName] 为插件返回的原始文件名：Android SAF 复制到缓存时，
  /// path 的基名有可能丢掉扩展名（如 content:// URI），此时用原始名兜底判定类型。
  static MediaItem? fromPath(String path, {String? fallbackName}) {
    var ext = p.extension(path).replaceFirst('.', '');
    if (ext.isEmpty && fallbackName != null) {
      ext = p.extension(fallbackName).replaceFirst('.', '');
    }
    final type = MediaExt.classifyExt(ext);
    if (type == null) return null;
    final base = p.basename(path);
    final name = p.extension(base).isNotEmpty
        ? base
        : ((fallbackName != null && fallbackName.isNotEmpty) ? fallbackName : base);
    return MediaItem(path: path, name: name, type: type);
  }

  /// 由 URL 构造（远程）
  static MediaItem? fromUrl(String url, {int? size}) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final seg = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
    final ext = p.extension(seg).replaceFirst('.', '');
    final type = MediaExt.classifyExt(ext);
    if (type == null) return null;
    final name = seg.isNotEmpty ? Uri.decodeComponent(seg) : url;
    return MediaItem(path: url, name: name, type: type, size: size ?? 0, url: true);
  }
}

/// 类型元信息（图标 + 中文名）—— 对应桌面版 TYPE_META
class TypeMeta {
  final String label;
  const TypeMeta(this.label);

  static const Map<MediaType, TypeMeta> map = {
    MediaType.image: TypeMeta('图片'),
    MediaType.video: TypeMeta('视频'),
    MediaType.audio: TypeMeta('音乐'),
  };

  static TypeMeta of(MediaType t) => map[t]!;
}

/// 人类可读体积 —— 对应 humanSize()
String humanSize(int? b) {
  if (b == null) return '';
  if (b < 1024) return '$b B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var i = -1;
  do {
    v /= 1024;
    i++;
  } while (v >= 1024 && i < units.length - 1);
  return '${v.toStringAsFixed(1)} ${units[i]}';
}

/// 时间格式化 —— 对应 fmtTime()
String fmtTime(num sec) {
  var s = sec.toDouble();
  if (!s.isFinite || s < 0) s = 0;
  final secI = (s % 60).floor();
  final minI = ((s / 60).floor()) % 60;
  final hr = (s / 3600).floor();
  String two(int n) => n.toString().padLeft(2, '0');
  return hr > 0 ? '$hr:${two(minI)}:${two(secI)}' : '$minI:${two(secI)}';
}