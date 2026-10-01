import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../models/app_settings.dart';
import '../models/media_item.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// 视频查看器 —— 对应 #view-video / #video-el / #vid-pause-badge
///
/// 桌面版：单击切换播放、双击全屏、水平拖动快进/退；画面按 vidFit 适配，
/// 并叠加亮度/对比度/饱和度滤镜（CSS filter brightness/contrast/saturate）。
class VideoStageView extends StatefulWidget {
  final VoidCallback onToggleFullscreen;
  const VideoStageView({super.key, required this.onToggleFullscreen});

  @override
  State<VideoStageView> createState() => _VideoStageViewState();
}

class _VideoStageViewState extends State<VideoStageView> {
  double _dragStartPos = 0;
  double _dragDx = 0;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final c = SylphColorsScope.of(context);
    final ctrl = st.videoHandle?.controller;

    if (ctrl == null || !ctrl.value.isInitialized) {
      return Container(
        color: c.bg,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
            const SizedBox(height: 12),
            Text('正在准备视频…', style: TextStyle(color: c.textDim, fontSize: 13)),
          ],
        ),
      );
    }

    final size = ctrl.value.size;
    final aspect = (size.width > 0 && size.height > 0)
        ? size.width / size.height
        : 16 / 9;

    return LayoutBuilder(
      builder: (ctx, cons) {
        final stageW = cons.maxWidth;
        final fit = switch (st.settings.vidFit) {
          VidFit.contain => BoxFit.contain,
          VidFit.cover => BoxFit.cover,
          VidFit.fill => BoxFit.fill,
        };

        Widget video = SizedBox.expand(
          child: FittedBox(
            fit: fit,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: aspect * 1000,
              height: 1000,
              child: VideoPlayer(ctrl),
            ),
          ),
        );

        // 画面滤镜（默认值时不加滤镜，省性能且视觉等价）
        final s = st.settings;
        if (s.picBrightness != 100 ||
            s.picContrast != 100 ||
            s.picSaturation != 100) {
          video = ColorFiltered(
            colorFilter: ColorFilter.matrix(
              _picFilterMatrix(
                s.picBrightness / 100.0,
                s.picContrast / 100.0,
                s.picSaturation / 100.0,
              ),
            ),
            child: video,
          );
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => st.togglePlay(),
          onDoubleTap: widget.onToggleFullscreen,
          onHorizontalDragStart: (d) {
            _dragging = true;
            _dragDx = 0;
            _dragStartPos = st.positionSec;
          },
          onHorizontalDragUpdate: (d) {
            _dragDx += d.delta.dx;
            final dur = st.durationSec;
            if (dur <= 0 || stageW <= 0) return;
            final target = (_dragStartPos + _dragDx / stageW * dur).clamp(0.0, dur);
            st.seekTo(target);
          },
          onHorizontalDragEnd: (_) => _dragging = false,
          child: Stack(
            children: [
              Positioned.fill(child: Container(color: c.bg)),
              Positioned.fill(child: video),
              // 暂停中央大播放图标（对应 .vid-pause-badge）
              if (!ctrl.value.isPlaying)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Center(
                      child: FaIcon(
                        FontAwesomeIcons.play,
                        size: 54,
                        color: Colors.white.withAlpha(210),
                        shadows: const [
                          Shadow(color: Colors.black54, blurRadius: 18),
                        ],
                      ),
                    ),
                  ),
                ),
              // 拖动快进时的进度提示
              if (_dragging)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 16,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(150),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        fmtTime(st.positionSec),
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 合成画面滤镜矩阵：CSS filter 的 brightness() contrast() saturate() 顺序
/// 等价于 saturate · contrast · brightness 的矩阵连乘（4×5 仿射矩阵）。
List<double> _picFilterMatrix(double b, double c, double s) {
  // brightness
  final B = <double>[
    b, 0, 0, 0, 0, //
    0, b, 0, 0, 0, //
    0, 0, b, 0, 0, //
    0, 0, 0, 1, 0, //
  ];
  // contrast（围绕 128 中点缩放）
  final off = (1 - c) * 128;
  final C = <double>[
    c, 0, 0, 0, off, //
    0, c, 0, 0, off, //
    0, 0, c, 0, off, //
    0, 0, 0, 1, 0, //
  ];
  // saturate
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  final S = <double>[
    lr + (1 - lr) * s, lg - lg * s, lb - lb * s, 0, 0, //
    lr - lr * s, lg + (1 - lg) * s, lb - lb * s, 0, 0, //
    lr - lr * s, lg - lg * s, lb + (1 - lb) * s, 0, 0, //
    0, 0, 0, 1, 0, //
  ];
  return _mul(S, _mul(C, B));
}

/// 4×5 仿射矩阵相乘（先作用 n 再作用 m）
List<double> _mul(List<double> m, List<double> n) {
  final out = List<double>.filled(20, 0);
  for (var row = 0; row < 4; row++) {
    for (var col = 0; col < 5; col++) {
      var v = 0.0;
      for (var k = 0; k < 4; k++) {
        v += m[row * 5 + k] * n[k * 5 + col];
      }
      if (col == 4) v += m[row * 5 + 4];
      out[row * 5 + col] = v;
    }
  }
  return out;
}