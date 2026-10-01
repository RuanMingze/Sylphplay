import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

/// 播放模式 —— 对应桌面版 MODES
enum PlayMode { off, one, all, sequence, shuffleSmart, shuffle }

extension PlayModeX on PlayMode {
  String get id => switch (this) {
        PlayMode.off => 'off',
        PlayMode.one => 'one',
        PlayMode.all => 'all',
        PlayMode.sequence => 'sequence',
        PlayMode.shuffleSmart => 'shuffle_smart',
        PlayMode.shuffle => 'shuffle',
      };

  /// 中文名 —— 对应 MODES[*].label
  String get label => switch (this) {
        PlayMode.off => '无',
        PlayMode.one => '单曲循环',
        PlayMode.all => '列表循环',
        PlayMode.sequence => '顺序播放',
        PlayMode.shuffleSmart => '随机播放(智能)',
        PlayMode.shuffle => '随机播放',
      };

  /// Font Awesome 图标 —— 对应 MODES[*].ico
  FaIconData get icon => switch (this) {
        PlayMode.off => FontAwesomeIcons.ban,
        PlayMode.one => FontAwesomeIcons.repeat,
        PlayMode.all => FontAwesomeIcons.arrowsRotate,
        PlayMode.sequence => FontAwesomeIcons.arrowRightLong,
        PlayMode.shuffleSmart => FontAwesomeIcons.wandSparkles,
        PlayMode.shuffle => FontAwesomeIcons.shuffle,
      };
}

PlayMode playModeFromId(String? id) {
  switch (id) {
    case 'off':
      return PlayMode.off;
    case 'one':
      return PlayMode.one;
    case 'sequence':
      return PlayMode.sequence;
    case 'shuffle_smart':
      return PlayMode.shuffleSmart;
    case 'shuffle':
      return PlayMode.shuffle;
    case 'all':
    default:
      return PlayMode.all;
  }
}

/// 图片适应方式
enum ImgFit { contain, actual, fill }

/// 视频适应方式
enum VidFit { contain, cover, fill }

/// 应用设置 —— 对应桌面版 DEFAULT_SETTINGS / S.settings
class AppSettings {
  String theme; // system | dark | light
  int defaultVolume;
  double defaultSpeed;
  PlayMode playMode;
  bool autoNext;
  ImgFit imgFit;
  bool imgMap;
  bool vizEnabled;
  bool recursiveFolder;
  bool showHints;
  int seekStep;
  int seekStepLong;
  int picBrightness;
  int picContrast;
  int picSaturation;
  VidFit vidFit;
  bool rememberProgress;
  int lyricsLines;
  bool lyricsEnabled;
  String accentColor;
  // —— 实验性功能 ——
  bool expSpeedSlider;
  double speedMin;
  double speedMax;
  bool expLyricsFill;
  bool expAutoLyrics;
  bool natQuiet; // 国庆彩蛋：临时切回默认深浅主题

  AppSettings({
    this.theme = 'system',
    this.defaultVolume = 80,
    this.defaultSpeed = 1,
    this.playMode = PlayMode.all,
    this.autoNext = true,
    this.imgFit = ImgFit.contain,
    this.imgMap = false,
    this.vizEnabled = true,
    this.recursiveFolder = true,
    this.showHints = true,
    this.seekStep = 5,
    this.seekStepLong = 60,
    this.picBrightness = 100,
    this.picContrast = 100,
    this.picSaturation = 100,
    this.vidFit = VidFit.contain,
    this.rememberProgress = true,
    this.lyricsLines = 7,
    this.lyricsEnabled = true,
    this.accentColor = '',
    this.expSpeedSlider = false,
    this.speedMin = 0.25,
    this.speedMax = 4,
    this.expLyricsFill = false,
    this.expAutoLyrics = false,
    this.natQuiet = false,
  });

  Map<String, dynamic> toJson() => {
        'theme': theme,
        'defaultVolume': defaultVolume,
        'defaultSpeed': defaultSpeed,
        'playMode': playMode.id,
        'autoNext': autoNext,
        'imgFit': imgFit.name,
        'imgMap': imgMap,
        'vizEnabled': vizEnabled,
        'recursiveFolder': recursiveFolder,
        'showHints': showHints,
        'seekStep': seekStep,
        'seekStepLong': seekStepLong,
        'picBrightness': picBrightness,
        'picContrast': picContrast,
        'picSaturation': picSaturation,
        'vidFit': vidFit.name,
        'rememberProgress': rememberProgress,
        'lyricsLines': lyricsLines,
        'lyricsEnabled': lyricsEnabled,
        'accentColor': accentColor,
        'expSpeedSlider': expSpeedSlider,
        'speedMin': speedMin,
        'speedMax': speedMax,
        'expLyricsFill': expLyricsFill,
        'expAutoLyrics': expAutoLyrics,
        'natQuiet': natQuiet,
      };

  /// 解析（含旧 loopMode/shuffle → playMode 迁移，与桌面版 loadSettings 一致）
  static AppSettings fromJson(Map<String, dynamic> raw) {
    final s = AppSettings();
    // 迁移旧的 loopMode + shuffle → 新的 playMode
    if (raw['playMode'] == null) {
      if (raw['shuffle'] == true) {
        raw['playMode'] = 'shuffle';
      } else if (raw['loopMode'] == 'one') {
        raw['playMode'] = 'one';
      } else if (raw['loopMode'] == 'all') {
        raw['playMode'] = 'all';
      } else if (raw['loopMode'] == 'off') {
        raw['playMode'] = 'off';
      }
    }
    s.theme = _str(raw['theme'], s.theme);
    s.defaultVolume = _int(raw['defaultVolume'], s.defaultVolume);
    s.defaultSpeed = _dbl(raw['defaultSpeed'], s.defaultSpeed);
    s.playMode = playModeFromId(raw['playMode'] is String ? raw['playMode'] : null);
    s.autoNext = _bool(raw['autoNext'], s.autoNext);
    s.imgFit = _enumByName(ImgFit.values, raw['imgFit'], s.imgFit);
    s.imgMap = _bool(raw['imgMap'], s.imgMap);
    s.vizEnabled = _bool(raw['vizEnabled'], s.vizEnabled);
    s.recursiveFolder = _bool(raw['recursiveFolder'], s.recursiveFolder);
    s.showHints = _bool(raw['showHints'], s.showHints);
    s.seekStep = _int(raw['seekStep'], s.seekStep);
    s.seekStepLong = _int(raw['seekStepLong'], s.seekStepLong);
    s.picBrightness = _int(raw['picBrightness'], s.picBrightness);
    s.picContrast = _int(raw['picContrast'], s.picContrast);
    s.picSaturation = _int(raw['picSaturation'], s.picSaturation);
    s.vidFit = _enumByName(VidFit.values, raw['vidFit'], s.vidFit);
    s.rememberProgress = _bool(raw['rememberProgress'], s.rememberProgress);
    s.lyricsLines = _int(raw['lyricsLines'], s.lyricsLines);
    s.lyricsEnabled = _bool(raw['lyricsEnabled'], s.lyricsEnabled);
    s.accentColor = _str(raw['accentColor'], s.accentColor);
    s.expSpeedSlider = _bool(raw['expSpeedSlider'], s.expSpeedSlider);
    s.speedMin = _dbl(raw['speedMin'], s.speedMin);
    s.speedMax = _dbl(raw['speedMax'], s.speedMax);
    s.expLyricsFill = _bool(raw['expLyricsFill'], s.expLyricsFill);
    s.expAutoLyrics = _bool(raw['expAutoLyrics'], s.expAutoLyrics);
    s.natQuiet = _bool(raw['natQuiet'], s.natQuiet);
    return s;
  }

  static String _str(dynamic v, String d) => v is String ? v : d;
  static int _int(dynamic v, int d) => v is num ? v.toInt() : d;
  static double _dbl(dynamic v, double d) => v is num ? v.toDouble() : d;
  static bool _bool(dynamic v, bool d) => v is bool ? v : d;
  static T _enumByName<T extends Enum>(List<T> values, dynamic v, T d) {
    if (v is String) {
      for (final e in values) {
        if (e.name == v) return e;
      }
    }
    return d;
  }
}

/// 设置存取 —— 对应 localStorage key 'sylph:settings'
class SettingsStore {
  static const _key = 'sylph:settings';

  static Future<AppSettings> load() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_key);
    if (raw == null) return AppSettings();
    try {
      final map = jsonDecode(raw);
      if (map is Map<String, dynamic>) return AppSettings.fromJson(map);
      if (map is Map) return AppSettings.fromJson(map.cast<String, dynamic>());
    } catch (_) {}
    return AppSettings();
  }

  static Future<void> save(AppSettings s) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_key, jsonEncode(s.toJson()));
  }
}

/// 把 #rrggbb 混入白色，返回变浅后的 #rrggbb —— 对应 lighten()
String lightenHex(String hex, int amt) {
  final m = hex.replaceAll('#', '');
  if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(m)) return hex;
  final n = int.parse(m, radix: 16);
  final r = ((n >> 16) + amt).clamp(0, 255);
  final g = (((n >> 8) & 255) + amt).clamp(0, 255);
  final b = ((n & 255) + amt).clamp(0, 255);
  return '#${((r << 16) | (g << 8) | b).toRadixString(16).padLeft(6, '0')}';
}

/// 解析 #rrggbb → Color
Color? parseHexColor(String hex) {
  final m = hex.replaceAll('#', '').trim();
  if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(m)) return null;
  return Color(0xFF000000 | int.parse(m, radix: 16));
}