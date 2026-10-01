import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';

import '../logic/video_thumb.dart';
import '../models/media_item.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// 播放队列面板 —— 对应 #queue-panel
///
/// 桌面版为右侧推挤面板；触屏版改为右侧滑出覆盖层（由 AppShell 提供容器），
/// 内含：计数、列表/网格切换、清空、收起、搜索、类型筛选、拖拽排序。
class QueuePanel extends StatefulWidget {
  const QueuePanel({super.key});

  @override
  State<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends State<QueuePanel> {
  late final TextEditingController _search =
      TextEditingController(text: context.read<AppState>().qSearch);

  /// 视频缩略图缓存：path → bytes（null 表示抽取失败，沿用图标）
  final Map<String, Uint8List?> _thumbs = {};
  final Set<String> _thumbBusy = {};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final c = SylphColorsScope.of(context);
    final rows = st.filteredQueue();
    final filtering = rows.length != st.queue.length;
    final countText =
        filtering ? '${rows.length}/${st.queue.length}' : '${st.queue.length}';
    final isEmpty = st.queue.isEmpty;
    final noRow = rows.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // —— 头部：标题 + 计数 + 视图切换/清空/收起 ——
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
          child: Row(
            children: [
              const Text('播放队列',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: c.border),
                ),
                child: Text(countText,
                    style: TextStyle(fontSize: 11.5, color: c.textDim)),
              ),
              const Spacer(),
              _SegIconBtn(
                icon: FontAwesomeIcons.list,
                active: st.queueView != 'grid',
                tooltip: '列表视图',
                onTap: () => st.setQueueView('list'),
              ),
              _SegIconBtn(
                icon: FontAwesomeIcons.tableCells,
                active: st.queueView == 'grid',
                tooltip: '缩略图网格',
                onTap: () => st.setQueueView('grid'),
              ),
              _SegIconBtn(
                icon: FontAwesomeIcons.trashCan,
                active: false,
                tooltip: '清空',
                onTap: () => st.clearQueue(),
              ),
              _SegIconBtn(
                icon: FontAwesomeIcons.xmark,
                active: false,
                tooltip: '收起',
                onTap: () => st.setQueuePanelOpen(false),
              ),
            ],
          ),
        ),
        // —— 工具区：搜索 + 类型筛选 ——
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Column(
            children: [
              Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: c.border),
                ),
                child: Row(
                  children: [
                    FaIcon(FontAwesomeIcons.magnifyingGlass,
                        size: 12, color: c.textDim),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _search,
                        onChanged: st.setQSearch,
                        style: const TextStyle(fontSize: 13),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: '搜索文件名…',
                          hintStyle:
                              TextStyle(color: c.textFaint, fontSize: 13),
                        ),
                      ),
                    ),
                    if (st.qSearch.isNotEmpty)
                      GestureDetector(
                        onTap: () {
                          _search.clear();
                          st.setQSearch('');
                        },
                        child: FaIcon(FontAwesomeIcons.xmark,
                            size: 12, color: c.textDim),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _FilterBtn(
                    label: '综合',
                    active: st.qFilter == 'all',
                    onTap: () => st.setQFilter('all'),
                  ),
                  const SizedBox(width: 6),
                  _FilterBtn(
                    label: '图片',
                    active: st.qFilter == 'image',
                    onTap: () => st.setQFilter('image'),
                  ),
                  const SizedBox(width: 6),
                  _FilterBtn(
                    label: '音乐',
                    active: st.qFilter == 'audio',
                    onTap: () => st.setQFilter('audio'),
                  ),
                  const SizedBox(width: 6),
                  _FilterBtn(
                    label: '视频',
                    active: st.qFilter == 'video',
                    onTap: () => st.setQFilter('video'),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: (isEmpty || noRow)
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      isEmpty ? '队列为空，点击顶栏「+」添加媒体' : '没有符合条件的项目',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: c.textFaint, fontSize: 13),
                    ),
                  ),
                )
              : (st.queueView == 'grid'
                  ? _buildGrid(st, c, rows)
                  : _buildList(st, c, rows)),
        ),
      ],
    );
  }

  /* ---------------- 列表视图（可拖拽排序） ---------------- */
  Widget _buildList(
    AppState st,
    SylphColors c,
    List<({MediaItem it, int qi})> rows,
  ) {
    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
      buildDefaultDragHandles: false,
      itemCount: rows.length,
      // onReorderItem 已自动补偿「先移除 oldIndex 再插入」导致的索引偏移，
      // 因此这里不再手动做 newIndex -= 1
      onReorderItem: (oldIndex, newIndex) {
        final ni = newIndex.clamp(0, rows.length - 1);
        st.reorderQueue(rows[oldIndex].qi, rows[ni].qi);
      },
      itemBuilder: (ctx, i) {
        final it = rows[i].it;
        final qi = rows[i].qi;
        final active = qi == st.current;
        return ReorderableDelayedDragStartListener(
          key: ValueKey('${it.path}#$qi'),
          index: i,
          child: InkWell(
            onTap: () => st.loadMedia(qi),
            borderRadius: BorderRadius.circular(9),
            child: Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
              decoration: BoxDecoration(
                color: active ? c.surface2 : c.surface,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: active ? c.accent : c.border),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 22,
                    child: FaIcon(_iconFor(it.type), size: 14, color: c.textDim),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          it.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${TypeMeta.of(it.type).label}'
                          '${it.size > 0 ? ' · ${humanSize(it.size)}' : ''}',
                          style: TextStyle(fontSize: 11, color: c.textFaint),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    iconSize: 15,
                    visualDensity: VisualDensity.compact,
                    tooltip: '从队列移除',
                    icon: FaIcon(FontAwesomeIcons.xmark, color: c.textDim),
                    onPressed: () => st.removeFromQueue(qi),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /* ---------------- 网格视图（可拖拽排序） ---------------- */
  Widget _buildGrid(
    AppState st,
    SylphColors c,
    List<({MediaItem it, int qi})> rows,
  ) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.80,
      ),
      itemCount: rows.length,
      itemBuilder: (ctx, i) {
        final it = rows[i].it;
        final qi = rows[i].qi;
        final active = qi == st.current;
        return DragTarget<int>(
          onWillAcceptWithDetails: (d) => d.data != qi,
          onAcceptWithDetails: (d) => st.reorderQueue(d.data, qi),
          builder: (ctx, cand, rej) {
            final hovering = cand.isNotEmpty;
            return LongPressDraggable<int>(
              data: qi,
              feedback: Material(
                color: Colors.transparent,
                child: Opacity(
                  opacity: .9,
                  child: _gridCard(st, c, it, qi, active, dragging: true),
                ),
              ),
              childWhenDragging: Opacity(
                opacity: .35,
                child: _gridCard(st, c, it, qi, active),
              ),
              child: GestureDetector(
                onTap: () => st.loadMedia(qi),
                child: _gridCard(st, c, it, qi, active, hover: hovering),
              ),
            );
          },
        );
      },
    );
  }

  Widget _gridCard(
    AppState st,
    SylphColors c,
    MediaItem it,
    int qi,
    bool active, {
    bool dragging = false,
    bool hover = false,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: active ? c.surface2 : c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: hover ? c.accent : (active ? c.accent : c.border),
          width: hover ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _thumb(st, it),
                // 移除按钮
                Positioned(
                  top: 2,
                  right: 2,
                  child: GestureDetector(
                    onTap: () => st.removeFromQueue(qi),
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(120),
                        shape: BoxShape.circle,
                      ),
                      child: const FaIcon(FontAwesomeIcons.xmark,
                          size: 11, color: Colors.white),
                    ),
                  ),
                ),
                // 当前播放标记
                if (active)
                  Positioned(
                    left: 4,
                    bottom: 4,
                    child: FaIcon(FontAwesomeIcons.volumeHigh,
                        size: 12, color: c.accent),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(7, 5, 7, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  it.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  '${TypeMeta.of(it.type).label}'
                  '${it.size > 0 ? ' · ${humanSize(it.size)}' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: c.textFaint),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 缩略图：图片直接用源图；视频异步抽帧后替换；音频/失败/远程视频用图标
  Widget _thumb(AppState st, MediaItem it) {
    final c = SylphColorsScope.of(context);
    if (it.type == MediaType.image) {
      final img = it.url
          ? Image.network(it.path, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _iconThumb(it, c))
          : Image.file(File(it.path), fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _iconThumb(it, c));
      return img;
    }
    if (it.type == MediaType.audio) return _iconThumb(it, c);
    // 视频
    if (it.url) return _iconThumb(it, c); // 跨域视频无法抽帧
    if (_thumbs.containsKey(it.path)) {
      final bytes = _thumbs[it.path];
      if (bytes == null) return _iconThumb(it, c);
      return Image.memory(bytes, fit: BoxFit.cover);
    }
    _captureVideoThumb(it);
    return _iconThumb(it, c);
  }

  Widget _iconThumb(MediaItem it, SylphColors c) {
    return Container(
      color: c.bgPanel,
      alignment: Alignment.center,
      child: FaIcon(_iconFor(it.type), size: 26, color: c.textFaint),
    );
  }

  /// 视频抽帧：seek 到前 25% 处避开开头黑屏（对应桌面版 captureVideoThumb）。
  /// 时长探测与定位都在原生侧完成，这里不再用 video_player 预探。
  Future<void> _captureVideoThumb(MediaItem it) async {
    if (_thumbBusy.contains(it.path)) return;
    _thumbBusy.add(it.path);
    _thumbs[it.path] = null; // 占位，避免重复触发
    final bytes = await VideoThumbService.instance.frame(it.path);
    if (!mounted) return;
    setState(() => _thumbs[it.path] = bytes);
  }

  static FaIconData _iconFor(MediaType t) => switch (t) {
        MediaType.image => FontAwesomeIcons.image,
        MediaType.video => FontAwesomeIcons.film,
        MediaType.audio => FontAwesomeIcons.music,
      };
}

/* ============================================================
   小控件
   ============================================================ */
class _SegIconBtn extends StatelessWidget {
  final FaIconData icon;
  final bool active;
  final String tooltip;
  final VoidCallback onTap;
  const _SegIconBtn({
    required this.icon,
    required this.active,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = SylphColorsScope.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: Container(
          width: 30,
          height: 30,
          margin: const EdgeInsets.only(left: 4),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? c.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: active ? c.accent : c.border),
          ),
          child: FaIcon(icon, size: 12, color: active ? c.accentInk : c.textDim),
        ),
      ),
    );
  }
}

class _FilterBtn extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _FilterBtn({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = SylphColorsScope.of(context);
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: Container(
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? c.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: active ? c.accent : c.border),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: active ? c.accentInk : c.textDim,
              fontWeight: active ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}