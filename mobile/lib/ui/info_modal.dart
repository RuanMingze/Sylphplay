import 'dart:io';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../models/media_item.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// 文件信息弹窗 —— 对应 openInfo() / #info-mask .info-block
///
/// 名称 / 类型 / 路径 / 大小 / 时长 / 分辨率。
Future<void> showInfoModal(BuildContext context, AppState st) async {
  final item = st.currentItem;
  if (item == null) {
    st.showToast('当前没有媒体');
    return;
  }
  // 自行解析配色：弹窗位于 Navigator overlay，取不到 AppShell 内的 SylphColorsScope
  final colors = resolveColors(
    settings: st.settings,
    systemDark:
        MediaQuery.of(context).platformBrightness == Brightness.dark,
    nationalActive: st.nationalActive,
  );

  // 大小：队列未记录时本地文件兜底 stat
  var size = item.size;
  if (size <= 0 && !item.url) {
    try {
      final stat = await File(item.path).stat();
      size = stat.size;
    } catch (_) {}
  }
  if (!context.mounted) return;

  String? duration;
  String? resolution;
  if (item.type == MediaType.video) {
    final d = st.durationSec;
    if (d > 0) duration = fmtTime(d);
    final ctrl = st.videoHandle?.controller;
    if (ctrl != null && ctrl.value.isInitialized) {
      final sz = ctrl.value.size;
      resolution = '${sz.width.round()} × ${sz.height.round()}';
    }
  } else if (item.type == MediaType.audio) {
    final d = st.durationSec;
    if (d > 0) duration = fmtTime(d);
  } else if (item.type == MediaType.image) {
    if (st.imgNatW > 0) resolution = '${st.imgNatW} × ${st.imgNatH}';
  }

  final rows = <({String k, String v, bool mono})>[
    (k: '名称', v: item.name, mono: false),
    (k: '类型', v: TypeMeta.of(item.type).label, mono: false),
    (k: '路径', v: item.path, mono: true),
    (k: '大小', v: size > 0 ? humanSize(size) : '—', mono: false),
    if (duration != null) (k: '时长', v: duration, mono: false),
    if (resolution != null) (k: '分辨率', v: resolution, mono: false),
  ];

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: colors.bgPanel,
      title: Row(
        children: [
          FaIcon(FontAwesomeIcons.circleInfo, size: 16, color: colors.accent),
          const SizedBox(width: 8),
          const Text('文件信息', style: TextStyle(fontSize: 16)),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 60,
                      child: Text(
                        r.k,
                        style: TextStyle(fontSize: 12.5, color: colors.textDim),
                      ),
                    ),
                    Expanded(
                      child: r.mono
                          ? SelectableText(
                              r.v,
                              style: const TextStyle(fontSize: 12.5, height: 1.4),
                            )
                          : Text(
                              r.v,
                              style: const TextStyle(fontSize: 13, height: 1.4),
                            ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          style: FilledButton.styleFrom(
            backgroundColor: colors.accent,
            foregroundColor: colors.accentInk,
          ),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}