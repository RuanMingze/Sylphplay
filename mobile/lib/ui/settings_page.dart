import 'dart:io';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';

import '../models/app_settings.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// iOS 无法自行遍历本地目录，相关设置项（递归扫描文件夹）在 iOS 上不显示
final bool _canPickFolder = Platform.isAndroid;

/// 设置页 —— 对应 #settings 弹窗（SETTING_TABS / SETTING_DEFS）
///
/// 移动端保留 5 个标签页「通用 / 图片 / 音乐 / 视频 / 实验性」，
/// 依移动端能力剔除桌面专属项：桌面歌词栏、托盘、后台永久刷新、窗口置顶、DLC。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// 当前配色（本页自建 SylphColorsScope，State 自身上下文在其之上，故缓存一份）
  SylphColors _c = SylphColors.dark;

  static const _tabs = <({String id, String label})>[
    (id: 'general', label: '通用'),
    (id: 'image', label: '图片'),
    (id: 'music', label: '音乐'),
    (id: 'video', label: '视频'),
    (id: 'experimental', label: '实验性'),
  ];

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final systemDark =
        MediaQuery.of(context).platformBrightness == Brightness.dark;
    final c = resolveColors(
      settings: st.settings,
      systemDark: systemDark,
      nationalActive: st.nationalActive,
    );
    _c = c;

    return SylphColorsScope(
      colors: c,
      child: Theme(
        data: c.toThemeData(),
        child: DefaultTabController(
          length: _tabs.length,
          // 设置页为整屏路由：额外让开 iOS 横屏刘海（左右安全区）；
          // 顶部由 AppBar、底部由 footer 各自处理。iPadOS 安全区为 0，无影响。
          child: ColoredBox(
            color: c.bg,
            child: SafeArea(
              top: false,
              bottom: false,
              child: Scaffold(
                backgroundColor: c.bg,
                appBar: AppBar(
                  backgroundColor: c.bgElev,
                  elevation: 0,
                  title: const Text('设置',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                  leading: IconButton(
                    icon: FaIcon(FontAwesomeIcons.chevronLeft, size: 16, color: c.text),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  bottom: TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    indicatorColor: c.accent,
                    labelColor: c.accent,
                    unselectedLabelColor: c.textDim,
                    tabs: [for (final t in _tabs) Tab(text: t.label)],
                  ),
                ),
                body: TabBarView(
                  children: [
                    _generalTab(st, c),
                    _imageTab(st, c),
                    _musicTab(st, c),
                    _videoTab(st, c),
                    _experimentalTab(st, c),
                  ],
                ),
                bottomNavigationBar: _footer(st, c),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /* ============================================================
     通用
     ============================================================ */
  Widget _generalTab(AppState st, SylphColors c) {
    final s = st.settings;
    return _list([
      _tile(
        '界面主题',
        '跟随系统 / 深色 / 浅色',
        _seg<String>(
          c,
          [
            (value: 'system', label: '跟随系统'),
            (value: 'dark', label: '深色'),
            (value: 'light', label: '浅色'),
          ],
          s.theme,
          (v) => st.updateSettings((x) => x.theme = v),
        ),
      ),
      _tile(
        '主题色',
        '默认用界面主题色，点色块自定义；点重置恢复默认',
        _accentPicker(st, c),
      ),
      _tile(
        '默认音量',
        '新播放项的音量',
        _slider(
          c,
          value: s.defaultVolume.toDouble(),
          min: 0,
          max: 100,
          label: '${s.defaultVolume}%',
          onChanged: (v) => st.setVolumeValue(v),
          onChangeEnd: (v) => st.setVolumeValue(v, remember: true),
        ),
        stacked: true,
      ),
      _tile(
        '默认播放速度',
        '全局速度',
        _select<double>(
          c,
          _speedOptions(s.defaultSpeed),
          s.defaultSpeed,
          (v) => st.setSpeed(v),
        ),
      ),
      _tile(
        '播放模式',
        '无 / 单曲循环 / 列表循环 / 顺序 / 智能随机 / 随机',
        _select<String>(
          c,
          [
            for (final m in PlayMode.values) (value: m.id, label: m.label),
          ],
          s.playMode.id,
          (v) => st.setPlayMode(playModeFromId(v)),
        ),
      ),
      _tile(
        '自动播放下一项',
        '媒体结束自动切换',
        _switch(c, s.autoNext,
            (v) => st.updateSettings((x) => x.autoNext = v)),
      ),
      _tile(
        '记忆播放进度',
        '从上次暂停位置继续播放',
        _switch(c, s.rememberProgress,
            (v) => st.updateSettings((x) => x.rememberProgress = v)),
      ),
      if (_canPickFolder)
        _tile(
          '递归扫描文件夹',
          '添加文件夹时包含子目录',
          _switch(c, s.recursiveFolder,
              (v) => st.updateSettings((x) => x.recursiveFolder = v)),
        ),
      // 国庆彩蛋激活时，允许临时切回默认深浅主题
      if (st.nationalActive)
        _tile(
          '切换为默认深浅主题',
          '国庆彩蛋激活中：临时关闭国庆红金配色与横幅，恢复正常外观',
          _switch(c, s.natQuiet,
              (v) => st.updateSettings((x) => x.natQuiet = v)),
        ),
    ]);
  }

  /* ============================================================
     图片
     ============================================================ */
  Widget _imageTab(AppState st, SylphColors c) {
    final s = st.settings;
    return _list([
      _tile(
        '图片适应方式',
        '打开图片时的默认缩放',
        _select<String>(
          c,
          [
            (value: 'contain', label: '适应窗口'),
            (value: 'actual', label: '原始大小'),
            (value: 'fill', label: '填满'),
          ],
          s.imgFit.name,
          (v) => st.updateSettings((x) => x.imgFit = ImgFit.values.firstWhere((e) => e.name == v)),
        ),
      ),
      _tile(
        '图片鹰眼图',
        '右下角显示整图与当前视野框',
        _switch(c, s.imgMap, (v) => st.updateSettings((x) => x.imgMap = v)),
      ),
      _tile(
        '显示图片操作提示',
        '',
        _switch(c, s.showHints,
            (v) => st.updateSettings((x) => x.showHints = v)),
      ),
    ]);
  }

  /* ============================================================
     音乐
     ============================================================ */
  Widget _musicTab(AppState st, SylphColors c) {
    final s = st.settings;
    return _list([
      _tile(
        '显示歌词',
        '主歌词开关；关闭时回到频谱',
        _switch(c, s.lyricsEnabled, (v) async {
          await st.updateSettings((x) => x.lyricsEnabled = v);
          await st.applyLyricsVisibility();
        }),
      ),
      _tile(
        '音频可视化',
        '播放时显示频谱；歌曲没有可用歌词（或「显示歌词」已关闭）时也会显示频谱 —— 属正常现象',
        _switch(c, s.vizEnabled,
            (v) => st.updateSettings((x) => x.vizEnabled = v)),
      ),
      _tile(
        '歌词显示行数',
        '歌词页一屏显示多少行',
        _slider(
          c,
          value: s.lyricsLines.toDouble(),
          min: 3,
          max: 12,
          divisions: 9,
          label: '${s.lyricsLines} 行',
          onChanged: (v) =>
              st.updateSettings((x) => x.lyricsLines = v.round()),
        ),
        stacked: true,
      ),
    ]);
  }

  /* ============================================================
     视频
     ============================================================ */
  Widget _videoTab(AppState st, SylphColors c) {
    final s = st.settings;
    return _list([
      _tile(
        '方向键步进·短(秒)',
        '←→ 快进/退',
        _select<int>(
          c,
          [
            (value: 3, label: '3 秒'),
            (value: 5, label: '5 秒'),
            (value: 10, label: '10 秒'),
            (value: 30, label: '30 秒'),
          ],
          s.seekStep,
          (v) => st.updateSettings((x) => x.seekStep = v),
        ),
      ),
      _tile(
        '方向键步进·长(秒)',
        '↑↓ 快进/退',
        _select<int>(
          c,
          [
            (value: 30, label: '30 秒'),
            (value: 60, label: '1 分钟'),
            (value: 120, label: '2 分钟'),
            (value: 300, label: '5 分钟'),
          ],
          s.seekStepLong,
          (v) => st.updateSettings((x) => x.seekStepLong = v),
        ),
      ),
      _tile(
        '视频适应方式',
        '仅作用于视频，不影响图片',
        _select<String>(
          c,
          [
            (value: 'contain', label: '适应'),
            (value: 'cover', label: '填满'),
            (value: 'fill', label: '拉伸'),
          ],
          s.vidFit.name,
          (v) => st.updateSettings((x) => x.vidFit = VidFit.values.firstWhere((e) => e.name == v)),
        ),
      ),
      _tile(
        '画面亮度',
        '视频画面亮度调节',
        _slider(
          c,
          value: s.picBrightness.toDouble(),
          min: 50,
          max: 150,
          label: '${s.picBrightness}%',
          onChanged: (v) =>
              st.updateSettings((x) => x.picBrightness = v.round()),
        ),
        stacked: true,
      ),
      _tile(
        '画面对比度',
        '视频画面对比度',
        _slider(
          c,
          value: s.picContrast.toDouble(),
          min: 50,
          max: 150,
          label: '${s.picContrast}%',
          onChanged: (v) =>
              st.updateSettings((x) => x.picContrast = v.round()),
        ),
        stacked: true,
      ),
      _tile(
        '画面饱和度',
        '视频画面色彩饱和度',
        _slider(
          c,
          value: s.picSaturation.toDouble(),
          min: 0,
          max: 200,
          label: '${s.picSaturation}%',
          onChanged: (v) =>
              st.updateSettings((x) => x.picSaturation = v.round()),
        ),
        stacked: true,
      ),
    ]);
  }

  /* ============================================================
     实验性
     ============================================================ */
  Widget _experimentalTab(AppState st, SylphColors c) {
    final s = st.settings;
    return _list([
      _tile(
        '实验：倍速滑块',
        '把控制条里的倍速下拉换成连续滑块（可自定义范围）',
        _switch(c, s.expSpeedSlider,
            (v) => st.updateSettings((x) => x.expSpeedSlider = v)),
      ),
      _tile(
        '倍速滑块·最小值',
        '滑块拖动到最左的速度',
        _speedInput(c, s.speedMin,
            (v) => st.updateSettings((x) => x.speedMin = v)),
      ),
      _tile(
        '倍速滑块·最大值',
        '滑块拖动到最右的速度',
        _speedInput(c, s.speedMax,
            (v) => st.updateSettings((x) => x.speedMax = v)),
      ),
      _tile(
        '实验：歌词逐字渐变填充',
        '歌词逐条播放，当前行文字自左向右逐字填充高亮（非卡拉OK歌词也生效）',
        _switch(c, s.expLyricsFill,
            (v) => st.updateSettings((x) => x.expLyricsFill = v)),
      ),
      _tile(
        '实验：自动寻找缺失歌词',
        '本地歌词缺失时，联网从 LRCLIB（免费、无需账户）查找，且要求歌词版本与歌曲时长匹配；未找到或请求失败则保持默认频谱页',
        _switch(c, s.expAutoLyrics,
            (v) => st.updateSettings((x) => x.expAutoLyrics = v)),
      ),
    ]);
  }

  /* ============================================================
     底部
     ============================================================ */
  Widget _footer(AppState st, SylphColors c) {
    return Container(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 10,
        bottom: MediaQuery.of(context).padding.bottom + 10,
      ),
      decoration: BoxDecoration(
        color: c.bgElev,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Text('Ruanftrix · Sylphplay',
              style: TextStyle(fontSize: 12, color: c.textFaint)),
          const Spacer(),
          FilledButton(
            onPressed: () => Navigator.of(context).maybePop(),
            style: FilledButton.styleFrom(
              backgroundColor: c.accent,
              foregroundColor: c.accentInk,
            ),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  /* ============================================================
     通用构件
     ============================================================ */
  Widget _list(List<Widget> children) => ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
        children: children,
      );

  Widget _tile(String title, String desc, Widget child,
      {bool stacked = false}) {
    final c = _c;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: c.bgPanel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _titleDesc(c, title, desc),
                const SizedBox(height: 10),
                child,
              ],
            )
          : Row(
              children: [
                Expanded(child: _titleDesc(c, title, desc)),
                const SizedBox(width: 10),
                child,
              ],
            ),
    );
  }

  Widget _titleDesc(SylphColors c, String title, String desc) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          if (desc.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(desc,
                style: TextStyle(fontSize: 11.5, color: c.textDim, height: 1.4)),
          ],
        ],
      );

  Widget _switch(SylphColors c, bool value, ValueChanged<bool> onChanged) =>
      Switch(value: value, onChanged: onChanged);

  Widget _seg<T>(
    SylphColors c,
    List<({T value, String label})> options,
    T value,
    ValueChanged<T> onChanged,
  ) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      alignment: WrapAlignment.end,
      children: [
        for (final o in options)
          InkWell(
            onTap: () => onChanged(o.value),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
              decoration: BoxDecoration(
                color: o.value == value ? c.accent : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: o.value == value ? c.accent : c.border),
              ),
              child: Text(
                o.label,
                style: TextStyle(
                  fontSize: 12,
                  color: o.value == value ? c.accentInk : c.textDim,
                  fontWeight:
                      o.value == value ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 默认速度下拉项；若当前值为自定义（实验倍速滑块设置过），补一项避免取值不匹配
  List<({double value, String label})> _speedOptions(double current) {
    final base = <double>[0.5, 0.75, 1, 1.25, 1.5, 2];
    final list = <({double value, String label})>[
      for (final v in base) (value: v, label: '${_trimSpeed(v)}×'),
    ];
    if (!base.any((v) => (v - current).abs() < 0.0001)) {
      list.add((value: current, label: '${_trimSpeed(current)}×'));
      list.sort((a, b) => a.value.compareTo(b.value));
    }
    return list;
  }

  static String _trimSpeed(double v) {
    if ((v - v.roundToDouble()).abs() < 0.0001) return v.round().toString();
    return v.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');
  }

  Widget _select<T>(
    SylphColors c,
    List<({T value, String label})> options,
    T value,
    ValueChanged<T> onChanged,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: true,
          dropdownColor: c.bgPanel,
          icon: FaIcon(FontAwesomeIcons.chevronDown, size: 11, color: c.textDim),
          style: TextStyle(fontSize: 12.5, color: c.text),
          items: [
            for (final o in options)
              DropdownMenuItem<T>(value: o.value, child: Text(o.label)),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }

  Widget _slider(
    SylphColors c, {
    required double value,
    required double min,
    required double max,
    int? divisions,
    required String label,
    required ValueChanged<double> onChanged,
    ValueChanged<double>? onChangeEnd,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
              ),
            ),
            SizedBox(
              width: 52,
              child: Text(label,
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 12.5, color: c.textDim)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _speedInput(SylphColors c, double value, ValueChanged<double> onChanged) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('× ', style: TextStyle(color: c.textDim, fontSize: 13)),
        SizedBox(
          width: 78,
          child: TextFormField(
            initialValue: value.toString(),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: c.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: c.accent),
              ),
            ),
            onChanged: (t) {
              final v = double.tryParse(t.trim());
              if (v != null && v >= 0.05) onChanged(v);
            },
          ),
        ),
      ],
    );
  }

  /* ---------------- 主题色取色 ---------------- */
  Widget _accentPicker(AppState st, SylphColors c) {
    final current = parseHexColor(st.settings.accentColor) ?? c.accent;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () => _openAccentDialog(st, c),
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: current,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.border),
            ),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: () => st.updateSettings((x) => x.accentColor = ''),
          icon: const FaIcon(FontAwesomeIcons.rotateLeft, size: 11),
          label: const Text('重置', style: TextStyle(fontSize: 12)),
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            side: BorderSide(color: c.border),
            foregroundColor: c.textDim,
          ),
        ),
      ],
    );
  }

  Future<void> _openAccentDialog(AppState st, SylphColors c) async {
    var hsv = HSVColor.fromColor(parseHexColor(st.settings.accentColor) ?? c.accent);
    final picked = await showDialog<HSVColor>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: c.bgPanel,
          title: const Text('自定义主题色', style: TextStyle(fontSize: 16)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  height: 44,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: hsv.toColor(),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: c.border),
                  ),
                ),
                _hsvSlider(c, '色相', hsv.hue, 0, 360, (v) {
                  setD(() => hsv = hsv.withHue(v));
                }),
                _hsvSlider(c, '饱和', hsv.saturation, 0, 1, (v) {
                  setD(() => hsv = hsv.withSaturation(v));
                }),
                _hsvSlider(c, '明度', hsv.value, 0, 1, (v) {
                  setD(() => hsv = hsv.withValue(v));
                }),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, hsv),
              style: FilledButton.styleFrom(
                backgroundColor: c.accent,
                foregroundColor: c.accentInk,
              ),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (picked != null) {
      final hex = _hexOf(picked.toColor());
      await st.updateSettings((x) => x.accentColor = hex);
    }
  }

  Widget _hsvSlider(SylphColors c, String label, double value, double min,
      double max, ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(
          width: 36,
          child: Text(label,
              style: TextStyle(fontSize: 12, color: c.textDim)),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  static String _hexOf(Color col) {
    String h(double v) =>
        (v * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
    return '#${h(col.r)}${h(col.g)}${h(col.b)}';
  }
}