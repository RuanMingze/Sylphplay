import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../models/app_settings.dart';
import '../models/media_item.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import 'audio_view.dart';
import 'image_view.dart';
import 'info_modal.dart';
import 'queue_panel.dart';
import 'settings_page.dart';
import 'video_view.dart';

/// iOS 无法自行遍历本地目录（沙盒限制、无分区扫描权限），因此隐藏「添加文件夹」入口
final bool _canPickFolder = Platform.isAndroid;

/// 全屏自动隐藏工具栏（触屏版）—— 对应桌面版 FsAutoHide
/// 桌面靠鼠标靠近边缘显示；触屏改为「点击屏幕切换显示」，并在 2.5s 空闲后自动隐藏。
class FsAutoHide {
  static const int idleMs = 2500; // IDLE_MS
  Timer? _t;
  final VoidCallback onHide;
  FsAutoHide(this.onHide);

  void schedule() {
    _t?.cancel();
    _t = Timer(const Duration(milliseconds: idleMs), onHide);
  }

  void cancel() {
    _t?.cancel();
    _t = null;
  }
}

/// 主骨架 —— 对应 index.html 的顶栏 / 主舞台 / 控制条 / 队列面板 / 设置弹窗
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final FsAutoHide _fsHide = FsAutoHide(() {
    if (!mounted) return;
    context.read<AppState>().setFsBarsVisible(false);
  });

  @override
  void dispose() {
    _fsHide.cancel();
    super.dispose();
  }

  Future<void> _toggleFullscreen() async {
    final st = context.read<AppState>();
    final next = !st.fullscreen;
    st.setFullscreen(next);
    if (next) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      _fsHide.schedule();
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      _fsHide.cancel();
    }
  }

  void _onStageTapForFullscreen() {
    final st = context.read<AppState>();
    if (!st.fullscreen) return;
    final show = !st.fsBarsVisible;
    st.setFsBarsVisible(show);
    if (show) {
      _fsHide.schedule();
    } else {
      _fsHide.cancel();
    }
  }

  /* ---------- 添加文件 / 文件夹 / URL ---------- */
  Future<void> _pickFiles() async {
    final st = context.read<AppState>();
    // file_picker 12+：pickFiles 直接返回 List<PlatformFile>，取消时为空列表
    final files = await FilePicker.pickFiles();
    // 记下每个 path 对应的原始文件名，供类型判定兜底（SAF 可能让 path 丢扩展名）
    final paths = <String>[];
    final names = <String, String>{};
    for (final f in files) {
      final path = f.path;
      if (path == null || path.isEmpty) continue;
      paths.add(path);
      names[path] = f.name;
    }
    if (paths.isNotEmpty) await st.addLocalPaths(paths, names: names);
  }

  Future<void> _pickFolder() async {
    final st = context.read<AppState>();
    // 扫描本地目录需要运行时权限（Android 13+ 是 READ_MEDIA_*）。没有权限时
    // Directory.list 会失败，旧代码静默吞掉后只报「找不到媒体文件」，误导排查。
    if (!await _ensureMediaPermission(st)) return;
    final dir = await FilePicker.getDirectoryPath();
    if (dir == null) return;
    await st.addLocalPaths([dir]);
  }

  /// 申请媒体读取权限；返回是否拿到
  Future<bool> _ensureMediaPermission(AppState st) async {
    if (!Platform.isAndroid) return true;
    // 两套权限都要带上，由系统按自身版本决定认哪个：
    //   API ≤32 → READ_EXTERNAL_STORAGE（Permission.storage），此时 READ_MEDIA_* 不存在
    //   API ≥33 → READ_MEDIA_AUDIO/VIDEO/IMAGES，此时 storage 已不可用
    // 关键：请求本版本不存在的权限时，系统不弹框、直接判 denied，
    // 所以只请求其中一套会在另一个版本上「静默失败」。
    final res = await <Permission>[
      Permission.storage,
      Permission.audio,
      Permission.videos,
      Permission.photos,
    ].request();
    if (res.values.any((s) => s.isGranted || s.isLimited)) return true;
    if (res.values.any((s) => s.isPermanentlyDenied)) {
      st.showToast('媒体权限已被永久拒绝，请在系统设置里手动开启');
      await openAppSettings();
    } else {
      st.showToast('没有媒体读取权限，无法扫描文件夹');
    }
    return false;
  }

  Future<void> _promptAddUrl() async {
    final st = context.read<AppState>();
    final ctrl = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(children: [
          FaIcon(FontAwesomeIcons.link, size: 16),
          SizedBox(width: 8),
          Text('添加 URL', style: TextStyle(fontSize: 17)),
        ]),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'https://…/图片.png 或 音频/视频链接',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('添加到队列'),
          ),
        ],
      ),
    );
    if (url != null && url.isNotEmpty) await st.addUrl(url);
  }

  void _showAddMenu() {
    final c = SylphColorsScope.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.bgPanel,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: FaIcon(FontAwesomeIcons.fileAudio, color: c.accent),
              title: const Text('选择文件'),
              onTap: () {
                Navigator.pop(ctx);
                _pickFiles();
              },
            ),
            if (_canPickFolder)
              ListTile(
                leading: FaIcon(FontAwesomeIcons.folderOpen, color: c.accent),
                title: const Text('添加文件夹'),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickFolder();
                },
              ),
            ListTile(
              leading: FaIcon(FontAwesomeIcons.link, color: c.accent),
              title: const Text('添加 URL'),
              onTap: () {
                Navigator.pop(ctx);
                _promptAddUrl();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openSettings() async {
    final st = context.read<AppState>();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => ChangeNotifierProvider<AppState>.value(
          value: st,
          child: const SettingsPage(),
        ),
      ),
    );
  }

  void _showInfo() {
    final st = context.read<AppState>();
    showInfoModal(context, st);
  }

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
    final showChrome = !st.fullscreen || st.fsBarsVisible;

    return SylphColorsScope(
      colors: c,
      child: Theme(
        data: c.toThemeData(),
        child: AppShellHost(
          openAddMenu: _showAddMenu,
          child: Scaffold(
            backgroundColor: c.bg,
            body: Stack(
              children: [
                Column(
                  children: [
                    // 顶栏（全屏且工具栏隐藏时收起）
                    AnimatedSize(
                      duration: const Duration(milliseconds: 220),
                      child: showChrome
                          ? _Topbar(onOpenSettings: _openSettings)
                          : const SizedBox.shrink(),
                    ),
                    // 国庆主题横幅
                    if (st.nationalActive && !st.settings.natQuiet)
                      _NatBanner(colors: c),
                    // 主舞台
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _onStageTapForFullscreen,
                        child: _Stage(
                          onToggleFullscreen: _toggleFullscreen,
                          onPickFiles: _pickFiles,
                          onPickFolder: _pickFolder,
                          fullscreen: st.fullscreen,
                        ),
                      ),
                    ),
                    // 控制条
                    AnimatedSize(
                      duration: const Duration(milliseconds: 220),
                      child: showChrome
                          ? _ControlBar(
                              onToggleFullscreen: _toggleFullscreen,
                              onOpenInfo: _showInfo,
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
                // 队列面板（右侧滑出，主内容让位不遮挡）
                _QueueOverlay(),
                // 提示
                _ToastLayer(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/* ============================================================
   顶栏
   ============================================================ */
class _Topbar extends StatelessWidget {
  final Future<void> Function() onOpenSettings;
  const _Topbar({required this.onOpenSettings});

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final c = SylphColorsScope.of(context);
    // iOS 灵动岛/刘海：四边都要让开（横屏时刘海在左右侧）；iPadOS 的安全区为 0，
    // 自动无额外内边距，无需分支。Android 沉浸态下 padding 归零，同样不冲突。
    final safe = MediaQuery.of(context).padding;
    return Container(
      decoration: BoxDecoration(
        color: c.bgElev,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      padding: EdgeInsets.only(
        top: safe.top + 6,
        left: safe.left + 12,
        right: safe.right + 6,
        bottom: 6,
      ),
      child: Row(
        children: [
          Image.asset('assets/icon.png', width: 26, height: 26),
          const SizedBox(width: 8),
          ShaderMask(
            shaderCallback: (r) => LinearGradient(
              colors: [c.accent2, c.accent],
            ).createShader(r),
            child: const Text(
              'Sylphplay',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 17,
                letterSpacing: .5,
                decoration: TextDecoration.none,
              ),
            ),
          ),
          const Spacer(),
          _IconBtn(
            icon: FontAwesomeIcons.plus,
            tooltip: _canPickFolder ? '添加文件 / 文件夹' : '添加文件',
            onTap: () => AppShellHost.of(context).openAddMenu(),
          ),
          _IconBtn(
            icon: FontAwesomeIcons.list,
            tooltip: '播放队列',
            onTap: () => st.toggleQueuePanel(),
          ),
          _IconBtn(
            icon: st.settings.theme == 'dark'
                ? FontAwesomeIcons.sun
                : FontAwesomeIcons.moon,
            tooltip: '切换深浅主题',
            onTap: () => st.toggleTheme(),
          ),
          _IconBtn(
            icon: FontAwesomeIcons.gear,
            tooltip: '设置',
            onTap: () => onOpenSettings(),
          ),
        ],
      ),
    );
  }
}

/// 让顶栏「+」按钮能触达 Shell 的 _showAddMenu
class AppShellHost extends InheritedWidget {
  final VoidCallback openAddMenu;
  const AppShellHost({super.key, required this.openAddMenu, required super.child});

  static AppShellHost of(BuildContext ctx) =>
      ctx.dependOnInheritedWidgetOfExactType<AppShellHost>()!;

  @override
  bool updateShouldNotify(AppShellHost oldWidget) => false;
}

/* ============================================================
   国庆横幅
   ============================================================ */
class _NatBanner extends StatelessWidget {
  final SylphColors colors;
  const _NatBanner({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFFB01F14), Color(0xFFE2231A), Color(0xFFB01F14)],
        ),
        border: Border(bottom: BorderSide(color: Color(0x59FFD700))),
      ),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FaIcon(FontAwesomeIcons.star, size: 11, color: SylphColors.nationalGold),
          SizedBox(width: 12),
          Flexible(
            child: Text(
              '热烈庆祝中华人民共和国成立77周年',
              style: TextStyle(
                color: SylphColors.nationalGold,
                fontWeight: FontWeight.w700,
                fontSize: 13,
                letterSpacing: 1,
              ),
            ),
          ),
          SizedBox(width: 12),
          FaIcon(FontAwesomeIcons.star, size: 11, color: SylphColors.nationalGold),
        ],
      ),
    );
  }
}

/* ============================================================
   主舞台
   ============================================================ */
class _Stage extends StatelessWidget {
  final VoidCallback onToggleFullscreen;
  final Future<void> Function() onPickFiles;
  final Future<void> Function() onPickFolder;
  final bool fullscreen;
  const _Stage({
    required this.onToggleFullscreen,
    required this.onPickFiles,
    required this.onPickFolder,
    required this.fullscreen,
  });

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final type = st.activeType;
    if (st.current < 0 || type == null) {
      return _EmptyState(onPickFiles: onPickFiles, onPickFolder: onPickFolder);
    }
    switch (type) {
      case MediaType.image:
        return const ImageStageView();
      case MediaType.video:
        return VideoStageView(
          onToggleFullscreen: onToggleFullscreen,
        );
      case MediaType.audio:
        return const AudioStageView();
    }
  }
}

class _EmptyState extends StatelessWidget {
  final Future<void> Function() onPickFiles;
  final Future<void> Function() onPickFolder;
  const _EmptyState({required this.onPickFiles, required this.onPickFolder});

  @override
  Widget build(BuildContext context) {
    final c = SylphColorsScope.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Opacity(
              opacity: .92,
              child: Image.asset('assets/icon.png', width: 96, height: 96),
            ),
            const SizedBox(height: 18),
            const Text('点按钮添加媒体文件',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
              '支持图片、视频、音乐 · 可从队列面板管理播放列表',
              style: TextStyle(color: c.textDim, fontSize: 13.5),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 12,
              children: [
                FilledButton(
                  onPressed: onPickFiles,
                  child: const Text('选择文件'),
                ),
                if (_canPickFolder)
                  OutlinedButton(
                    onPressed: onPickFolder,
                    child: const Text('添加文件夹'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/* ============================================================
   控制条
   ============================================================ */
class _ControlBar extends StatefulWidget {
  final VoidCallback onToggleFullscreen;
  final VoidCallback onOpenInfo;
  const _ControlBar({
    required this.onToggleFullscreen,
    required this.onOpenInfo,
  });

  @override
  State<_ControlBar> createState() => _ControlBarState();
}

class _ControlBarState extends State<_ControlBar> {
  double _dragVal = 0;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final c = SylphColorsScope.of(context);
    final item = st.currentItem;
    final type = st.activeType;
    final isImage = type == MediaType.image;
    final hasMedia = item != null && type != null;

    final safe = MediaQuery.of(context).padding;
    return Container(
      decoration: BoxDecoration(
        color: c.bgElev,
        border: Border(top: BorderSide(color: c.border)),
      ),
      padding: EdgeInsets.only(
        left: safe.left + 10,
        right: safe.right + 10,
        top: 8,
        bottom: safe.bottom + 8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 第一行：媒体信息 + 右侧控件
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: c.border),
                ),
                child: Text(
                  hasMedia ? TypeMeta.of(type).label : '—',
                  style: TextStyle(fontSize: 11.5, color: c.textDim),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GestureDetector(
                  onTap: hasMedia ? widget.onOpenInfo : null,
                  child: Text(
                    hasMedia ? item.name : '未选择媒体',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              if (!isImage && hasMedia) ...[
                _VolumeButton(),
                _SpeedButton(),
                _ModeButton(),
                _IconBtn(
                  icon: FontAwesomeIcons.circleInfo,
                  tooltip: '文件信息',
                  dense: true,
                  onTap: widget.onOpenInfo,
                ),
                if (type == MediaType.audio)
                  _IconBtn(
                    icon: FontAwesomeIcons.noteSticky,
                    tooltip: '导入歌词',
                    dense: true,
                    onTap: () => _importLyrics(context),
                  ),
              ],
              _IconBtn(
                icon: st.fullscreen
                    ? FontAwesomeIcons.compress
                    : FontAwesomeIcons.expand,
                tooltip: '全屏',
                dense: true,
                onTap: widget.onToggleFullscreen,
              ),
            ],
          ),
          const SizedBox(height: 6),
          // 第二行：图片控件 / 传输控件
          if (isImage)
            _ImageControls()
          else if (hasMedia)
            _TransportControls(
              dragging: _dragging,
              dragVal: _dragVal,
              onDragStart: (v) {
                setState(() {
                  _dragging = true;
                  _dragVal = v;
                });
                st.setSeeking(true);
              },
              onDragUpdate: (v) => setState(() => _dragVal = v),
              onDragEnd: (v) async {
                await st.seekTo(v);
                st.setSeeking(false);
                if (mounted) setState(() => _dragging = false);
              },
            )
          else
            const SizedBox(height: 6),
        ],
      ),
    );
  }

  Future<void> _importLyrics(BuildContext context) async {
    final st = context.read<AppState>();
    // 用 FileType.any：Android 的 SAF 是按 MIME 过滤的，而 .lrc 没有对应 MIME，
    // 用 FileType.custom + allowedExtensions 会让所有 lrc 在选择器里变灰点不动。
    // 因此放开选择，拿到文件后自己校验内容。
    final picked = await FilePicker.pickFile(type: FileType.any);
    if (picked == null) return;
    final path = picked.path;
    if (path == null || path.isEmpty) {
      st.showToast('无法读取该文件，请选择 LRC 歌词文件');
      return;
    }
    String content;
    try {
      // 读字节自行解码：lrc 多为 GBK（酷我等下载源），而 readAsString() 会按
      // 严格 utf-8 解码，遇到 GBK 中文直接抛 FormatException。
      content = _decodeLrcBytes(await File(path).readAsBytes());
    } catch (_) {
      st.showToast('无法读取该文件，请选择 LRC 歌词文件');
      return;
    }
    if (!content.contains('[')) {
      st.showToast('该文件不像 LRC 歌词，已取消导入');
      return;
    }
    st.importLyricsText(content);
  }
}

/// lrc 编码兜底：UTF-8 严格解码优先，失败按 GBK（酷我等下载源），
/// 再失败用宽松 UTF-8（保底不丢整份歌词）。
String _decodeLrcBytes(List<int> bytes) {
  if (bytes.isEmpty) return '';
  try {
    return utf8.decode(bytes);
  } on FormatException {
    // 非 UTF-8，落到 GBK
  }
  try {
    return gbk.decode(bytes);
  } catch (_) {
    return utf8.decode(bytes, allowMalformed: true);
  }
}

/// 传输控件（视频/音频）
class _TransportControls extends StatelessWidget {
  final bool dragging;
  final double dragVal;
  final ValueChanged<double> onDragStart;
  final ValueChanged<double> onDragUpdate;
  final ValueChanged<double> onDragEnd;
  const _TransportControls({
    required this.dragging,
    required this.dragVal,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final c = SylphColorsScope.of(context);
    final dur = st.durationSec;
    final pos = dragging ? dragVal : st.positionSec;
    final maxV = dur > 0 ? dur : 1.0;
    final value = pos.clamp(0.0, maxV);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _IconBtn(
              icon: FontAwesomeIcons.backwardStep,
              tooltip: '上一项',
              onTap: () => st.prev(),
            ),
            const SizedBox(width: 6),
            _PlayButton(),
            const SizedBox(width: 6),
            _IconBtn(
              icon: FontAwesomeIcons.forwardStep,
              tooltip: '下一项',
              onTap: () => st.next(),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            SizedBox(
              width: 46,
              child: Text(
                fmtTime(pos),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, color: c.textDim),
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6),
                ),
                child: Slider(
                  min: 0,
                  max: maxV,
                  value: value,
                  onChangeStart: onDragStart,
                  onChanged: onDragUpdate,
                  onChangeEnd: onDragEnd,
                ),
              ),
            ),
            SizedBox(
              width: 46,
              child: Text(
                fmtTime(dur > 0 ? dur : 0),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, color: c.textDim),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _PlayButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final c = SylphColorsScope.of(context);
    return _CircleBtn(
      icon: st.playing ? FontAwesomeIcons.pause : FontAwesomeIcons.play,
      color: c.accent,
      ink: c.accentInk,
      size: 46,
      onTap: () => st.togglePlay(),
    );
  }
}

/// 图片控件（上一张 / 缩放 / 适应 / 旋转 / 信息 / 下一张）
class _ImageControls extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final c = SylphColorsScope.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _IconBtn(
          icon: FontAwesomeIcons.chevronLeft,
          tooltip: '上一张',
          onTap: () => st.prev(),
        ),
        const SizedBox(width: 4),
        _IconBtn(
          icon: FontAwesomeIcons.minus,
          tooltip: '缩小',
          onTap: () => st.zoomToSmooth(-1),
        ),
        Container(
          width: 58,
          alignment: Alignment.center,
          child: Text(
            '${(st.imgZoom * 100).round()}%',
            style: TextStyle(fontSize: 12.5, color: c.textDim),
          ),
        ),
        _IconBtn(
          icon: FontAwesomeIcons.plus,
          tooltip: '放大',
          onTap: () => st.zoomToSmooth(1),
        ),
        const SizedBox(width: 4),
        _IconBtn(
          icon: FontAwesomeIcons.expand,
          tooltip: '适应窗口',
          onTap: () => st.fitToContain(),
        ),
        _IconBtn(
          icon: FontAwesomeIcons.rotateRight,
          tooltip: '旋转 90°',
          onTap: () => st.rotateImg(),
        ),
        _IconBtn(
          icon: FontAwesomeIcons.circleInfo,
          tooltip: '文件信息',
          onTap: () => showInfoModal(context, st),
        ),
        const SizedBox(width: 4),
        _IconBtn(
          icon: FontAwesomeIcons.chevronRight,
          tooltip: '下一张',
          onTap: () => st.next(),
        ),
      ],
    );
  }
}

/// 音量按钮（弹出滑条）
class _VolumeButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final c = SylphColorsScope.of(context);
    final v = st.settings.defaultVolume;
    return GestureDetector(
      onTap: () => _showVolumeSheet(context, st),
      child: Tooltip(
        message: '音量',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FaIcon(
                v <= 0
                    ? FontAwesomeIcons.volumeXmark
                    : (v < 45
                        ? FontAwesomeIcons.volumeLow
                        : FontAwesomeIcons.volumeHigh),
                size: 14,
                color: c.text,
              ),
              const SizedBox(width: 5),
              Text('$v', style: TextStyle(fontSize: 11.5, color: c.textDim)),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _showVolumeSheet(BuildContext context, AppState st) async {
  final c = SylphColorsScope.of(context);
  double local = st.settings.defaultVolume.toDouble();
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: c.bgPanel,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const FaIcon(FontAwesomeIcons.volumeHigh, size: 15),
                  const SizedBox(width: 8),
                  const Text('音量', style: TextStyle(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  Text('${local.round()}%',
                      style: TextStyle(color: c.textDim, fontSize: 12.5)),
                ],
              ),
              Slider(
                min: 0,
                max: 100,
                value: local,
                onChanged: (v) {
                  setSheet(() => local = v);
                  st.setVolumeValue(v);
                },
                onChangeEnd: (v) => st.setVolumeValue(v, remember: true),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 播放速度按钮（倍速下拉 或 实验性连续滑块）
class _SpeedButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final c = SylphColorsScope.of(context);
    return GestureDetector(
      onTap: () => st.settings.expSpeedSlider
          ? _showSpeedSliderSheet(context, st)
          : _showSpeedMenu(context, st),
      child: Tooltip(
        message: '播放速度',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Text(
            '${_trimSpeed(st.settings.defaultSpeed)}×',
            style: TextStyle(fontSize: 12, color: c.textDim),
          ),
        ),
      ),
    );
  }
}

String _trimSpeed(double v) {
  if ((v - v.roundToDouble()).abs() < 0.0001) return v.round().toString();
  return v.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');
}

const List<double> kSpeedOptions = [0.5, 0.75, 1, 1.25, 1.5, 2];

Future<void> _showSpeedMenu(BuildContext context, AppState st) async {
  final c = SylphColorsScope.of(context);
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: c.bgPanel,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final v in kSpeedOptions)
            ListTile(
              title: Text('${_trimSpeed(v)}×'),
              trailing: (st.settings.defaultSpeed - v).abs() < 0.0001
                  ? FaIcon(FontAwesomeIcons.check, size: 14, color: c.accent)
                  : null,
              onTap: () {
                Navigator.pop(ctx);
                st.setSpeed(v);
              },
            ),
        ],
      ),
    ),
  );
}

Future<void> _showSpeedSliderSheet(BuildContext context, AppState st) async {
  final c = SylphColorsScope.of(context);
  var lo = st.settings.speedMin;
  var hi = st.settings.speedMax;
  if (lo < 0.05) lo = 0.05;
  if (hi < lo) hi = lo;
  double local = st.settings.defaultSpeed.clamp(lo, hi);
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: c.bgPanel,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const FaIcon(FontAwesomeIcons.gaugeHigh, size: 15),
                  const SizedBox(width: 8),
                  const Text('播放速度', style: TextStyle(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  Text('${local.toStringAsFixed(2)}×',
                      style: TextStyle(color: c.textDim, fontSize: 12.5)),
                ],
              ),
              Slider(
                min: lo,
                max: hi,
                value: local,
                onChanged: (v) {
                  setSheet(() => local = v);
                  st.setSpeed(v);
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 播放模式按钮
class _ModeButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final c = SylphColorsScope.of(context);
    final mode = st.settings.playMode;
    return GestureDetector(
      onTap: () async {
        await showModalBottomSheet<void>(
          context: context,
          backgroundColor: c.bgPanel,
          builder: (ctx) => SafeArea(
            // 6 个选项在小屏/带手势条设备上会超出 bottom sheet 的默认高度，
            // 包一层滚动容器避免 Bottom Overflowed
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final m in PlayMode.values)
                    ListTile(
                      leading: FaIcon(m.icon, size: 15, color: c.accent),
                      title: Text(m.label),
                      trailing: m == mode
                          ? FaIcon(FontAwesomeIcons.check,
                              size: 14, color: c.accent)
                          : null,
                      onTap: () {
                        Navigator.pop(ctx);
                        st.setPlayMode(m);
                      },
                    ),
                ],
              ),
            ),
          ),
        );
      },
      child: Tooltip(
        message: '播放模式',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: FaIcon(
            mode.icon,
            size: 14,
            color: (mode == PlayMode.shuffle || mode == PlayMode.shuffleSmart)
                ? c.accent
                : c.text,
          ),
        ),
      ),
    );
  }
}

/* ============================================================
   队列面板（右侧滑出）
   ============================================================ */
class _QueueOverlay extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final c = SylphColorsScope.of(context);
    if (!st.queuePanelOpen) return const SizedBox.shrink();
    return Positioned.fill(
      child: Row(
        children: [
          // 主内容让位：左侧点击区关闭
          Expanded(
            child: GestureDetector(
              onTap: () => st.setQueuePanelOpen(false),
              child: Container(color: Colors.black54),
            ),
          ),
          SizedBox(
            width: 340,
            child: Container(
              decoration: BoxDecoration(
                color: c.bgPanel,
                border: Border(left: BorderSide(color: c.border)),
              ),
              // 面板贴合右缘：让开 iOS 灵动岛/Home 指示条（右侧与底部），
              // 左侧保留边框不额外内缩。iPadOS 安全区为 0，等同无变化。
              child: const SafeArea(left: false, child: QueuePanel()),
            ),
          ),
        ],
      ),
    );
  }
}

/* ============================================================
   提示层
   ============================================================ */
class _ToastLayer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final c = SylphColorsScope.of(context);
    final msg = st.toastMsg;
    return Positioned(
      left: 0,
      right: 0,
      bottom: MediaQuery.of(context).padding.bottom + 130,
      child: IgnorePointer(
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 240),
          opacity: msg == null ? 0 : 1,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: c.border),
              ),
              child: Text(msg ?? '', style: const TextStyle(fontSize: 13)),
            ),
          ),
        ),
      ),
    );
  }
}

/* ============================================================
   通用小控件
   ============================================================ */
class _IconBtn extends StatelessWidget {
  final FaIconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool dense;
  const _IconBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = SylphColorsScope.of(context);
    final s = dense ? 34.0 : 38.0;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          width: s,
          height: s,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: dense ? Colors.transparent : c.surface,
            borderRadius: BorderRadius.circular(9),
            border: dense ? null : Border.all(color: c.border),
          ),
          child: FaIcon(icon, size: dense ? 14 : 15, color: c.text),
        ),
      ),
    );
  }
}

class _CircleBtn extends StatelessWidget {
  final FaIconData icon;
  final Color color;
  final Color ink;
  final double size;
  final VoidCallback onTap;
  const _CircleBtn({
    required this.icon,
    required this.color,
    required this.ink,
    required this.size,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: FaIcon(icon, size: size * 0.38, color: ink),
      ),
    );
  }
}