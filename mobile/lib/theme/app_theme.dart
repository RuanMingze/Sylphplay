import 'package:flutter/material.dart';

import '../models/app_settings.dart';

/// 一套主题配色 —— 对应 styles.css 的 :root[data-theme] 变量
class SylphColors {
  final Color bg;
  final Color bgElev;
  final Color bgPanel;
  final Color surface;
  final Color surface2;
  final Color border;
  final Color text;
  final Color textDim;
  final Color textFaint;
  final Color accent;
  final Color accent2;
  final Color accentInk;

  const SylphColors({
    required this.bg,
    required this.bgElev,
    required this.bgPanel,
    required this.surface,
    required this.surface2,
    required this.border,
    required this.text,
    required this.textDim,
    required this.textFaint,
    required this.accent,
    required this.accent2,
    required this.accentInk,
  });

  static const dark = SylphColors(
    bg: Color(0xFF17120C),
    bgElev: Color(0xFF221911),
    bgPanel: Color(0xFF1D150C),
    surface: Color(0xFF2A1F13),
    surface2: Color(0xFF35281A),
    border: Color(0xFF3A2C1B),
    text: Color(0xFFF4E8D8),
    textDim: Color(0xFFB8A48C),
    textFaint: Color(0xFF7D6B55),
    accent: Color(0xFFFF7A00),
    accent2: Color(0xFFFF9A3D),
    accentInk: Color(0xFFFFFFFF),
  );

  static const light = SylphColors(
    bg: Color(0xFFFBF4EA),
    bgElev: Color(0xFFFFF6EA),
    bgPanel: Color(0xFFFFF4E3),
    surface: Color(0xFFFFE9CF),
    surface2: Color(0xFFFFDCA8),
    border: Color(0xFFECD5B6),
    text: Color(0xFF3A2612),
    textDim: Color(0xFF7C5F3F),
    textFaint: Color(0xFFB3966E),
    accent: Color(0xFFFF7A00),
    accent2: Color(0xFFFF9A3D),
    accentInk: Color(0xFFFFFFFF),
  );

  /// 中国红 / 帝王金 —— 国庆彩蛋
  static const nationalRed = Color(0xFFE2231A);
  static const nationalGold = Color(0xFFFFD700);

  SylphColors withAccent(Color accent, Color accent2) => SylphColors(
        bg: bg,
        bgElev: bgElev,
        bgPanel: bgPanel,
        surface: surface,
        surface2: surface2,
        border: border,
        text: text,
        textDim: textDim,
        textFaint: textFaint,
        accent: accent,
        accent2: accent2,
        accentInk: accentInk,
      );

  /// 应用于 Widget 树（供 Material 组件取色）
  ThemeData toThemeData() {
    final base = ThemeData(
      brightness: bg.computeLuminance() < 0.5 ? Brightness.dark : Brightness.light,
      useMaterial3: true,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
    );
    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: accent,
        secondary: accent2,
        surface: bgElev,
        onSurface: text,
        onPrimary: accentInk,
      ),
      textTheme: base.textTheme.apply(
        bodyColor: text,
        displayColor: text,
      ),
      dividerColor: border,
      iconTheme: IconThemeData(color: text),
      sliderTheme: base.sliderTheme.copyWith(
        activeTrackColor: accent,
        inactiveTrackColor: surface2,
        thumbColor: accent,
      ),
    );
  }
}

/// 根据设置 + 系统深浅 + 国庆彩蛋计算当前配色
SylphColors resolveColors({
  required AppSettings settings,
  required bool systemDark,
  required bool nationalActive,
}) {
  final dark = settings.theme == 'dark' ||
      (settings.theme != 'light' && systemDark);
  var c = dark ? SylphColors.dark : SylphColors.light;
  if (nationalActive && !settings.natQuiet) {
    return c.withAccent(SylphColors.nationalRed, SylphColors.nationalGold);
  }
  final custom = parseHexColor(settings.accentColor);
  if (custom != null) {
    return c.withAccent(custom, parseHexColor(lightenHex(settings.accentColor, 40)) ?? c.accent2);
  }
  return c;
}

/// 便捷取色：SylphColors.of(context)
class SylphColorsScope extends InheritedWidget {
  final SylphColors colors;
  const SylphColorsScope({super.key, required this.colors, required super.child});

  static SylphColors of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<SylphColorsScope>();
    return scope?.colors ?? SylphColors.dark;
  }

  @override
  bool updateShouldNotify(SylphColorsScope oldWidget) =>
      oldWidget.colors != colors;
}