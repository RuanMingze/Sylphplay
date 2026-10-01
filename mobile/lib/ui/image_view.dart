import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/media_item.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// 图片查看器 —— 对应 #view-image / #image-stage / #img-map-wrap
///
/// 桌面版：图片以 translate(-50%,-50%) 定位于 (imgLeftPct%, imgTopPct%)，
/// 施加 rotate(imgRot) scale(imgVz)；滚轮+Ctrl 缩放，拖动平移，右下角鹰眼图。
/// 触屏版等价：双指捏合缩放、单指拖动平移，鹰眼图可拖动视野框。
class ImageStageView extends StatefulWidget {
  const ImageStageView({super.key});

  @override
  State<ImageStageView> createState() => _ImageStageViewState();
}

class _ImageStageViewState extends State<ImageStageView> {
  ImageProvider? _provider;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ui.Image? _uiImg;
  String? _resolvedPath;

  double _scaleStartZoom = 1;
  Offset _lastFocal = Offset.zero;

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  void _detach() {
    final s = _stream, l = _listener;
    if (s != null && l != null) s.removeListener(l);
    _stream = null;
    _listener = null;
  }

  void _resolveFor(MediaItem item) {
    _detach();
    final ImageProvider provider;
    if (item.url) {
      provider = NetworkImage(item.path);
    } else {
      provider = FileImage(File(item.path));
    }
    _provider = provider;
    final stream = provider.resolve(ImageConfiguration.empty);
    _stream = stream;
    final listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        setState(() => _uiImg = info.image);
        context.read<AppState>().setImageNaturalSize(
              info.image.width,
              info.image.height,
            );
      },
      onError: (Object e, StackTrace? st) {
        // 解码失败：保持图标态，不覆盖自然尺寸
      },
    );
    _listener = listener;
    stream.addListener(listener);
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final c = SylphColorsScope.of(context);
    final item = st.currentItem;
    if (item == null) return const SizedBox.shrink();

    // 当前项变化 → 解析新图片并取自然尺寸
    if (item.path != _resolvedPath) {
      _resolvedPath = item.path;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _resolveFor(item);
      });
    }

    return LayoutBuilder(
      builder: (ctx, cons) {
        final w = cons.maxWidth;
        final h = cons.maxHeight;
        // 上报舞台尺寸（对应 imageStage clientWidth/clientHeight）
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) st.setStageSize(w, h);
        });

        final dispW = st.imgDispW;
        final dispH = st.imgDispH;
        final angle = st.imgRot * math.pi / 180.0;
        final vz = st.imgVz;

        return ClipRect(
          child: Stack(
            children: [
              // 舞台底色
              Positioned.fill(child: Container(color: c.bg)),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: (d) {
                  _scaleStartZoom = st.imgZoom;
                  _lastFocal = d.focalPoint;
                },
                onScaleUpdate: (d) {
                  if (d.pointerCount >= 2) {
                    // 双指捏合 → 缩放
                    if (d.scale != 1.0) st.zoomTo(_scaleStartZoom * d.scale);
                  } else {
                    // 单指拖动 → 平移
                    final delta = d.focalPoint - _lastFocal;
                    if (delta != Offset.zero) {
                      st.panImageBy(delta.dx, delta.dy);
                    }
                  }
                  _lastFocal = d.focalPoint;
                },
                child: Stack(
                  children: [
                    if (_provider != null && dispW > 0 && dispH > 0)
                      Positioned(
                        left: st.imgLeftPct / 100 * w - dispW / 2,
                        top: st.imgTopPct / 100 * h - dispH / 2,
                        width: dispW,
                        height: dispH,
                        child: Transform.rotate(
                          angle: angle,
                          child: Transform.scale(
                            scale: vz,
                            child: Image(
                              image: _provider!,
                              fit: BoxFit.fill,
                              gaplessPlayback: true,
                              filterQuality: FilterQuality.medium,
                              errorBuilder: (_, __, ___) => Center(
                                child: Text(
                                  '无法显示该图片',
                                  style: TextStyle(color: c.textDim, fontSize: 13),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (_provider == null)
                      Center(
                        child: Text(
                          '正在解码…',
                          style: TextStyle(color: c.textDim, fontSize: 13),
                        ),
                      ),
                  ],
                ),
              ),
              // 右下角鹰眼图
              if (st.settings.imgMap && st.imgNatW > 0)
                Positioned(
                  right: 14,
                  bottom: 14,
                  child: _EagleMap(
                    image: _uiImg,
                    colors: c,
                    onMove: (px, py) => st.setImgViewportFromMap(px, py),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 鹰眼图 —— 对应 .img-map-wrap（200×120 逻辑画布）+ .img-map-win 视野框
class _EagleMap extends StatelessWidget {
  final ui.Image? image;
  final SylphColors colors;
  final void Function(double px, double py) onMove;
  const _EagleMap({
    required this.image,
    required this.colors,
    required this.onMove,
  });

  static const double cw = 200, ch = 120;

  @override
  Widget build(BuildContext context) {
    void handle(Offset local) {
      final px = local.dx.clamp(0.0, cw);
      final py = local.dy.clamp(0.0, ch);
      onMove(px, py);
    }

    return GestureDetector(
      onTapDown: (d) => handle(d.localPosition),
      onPanStart: (d) => handle(d.localPosition),
      onPanUpdate: (d) => handle(d.localPosition),
      child: Container(
        width: cw,
        height: ch,
        decoration: BoxDecoration(
          color: colors.bgPanel.withAlpha(220),
          border: Border.all(color: colors.border),
          borderRadius: BorderRadius.circular(10),
        ),
        clipBehavior: Clip.antiAlias,
        child: CustomPaint(
          painter: _EaglePainter(
            image: image,
            geom: context.watch<AppState>().mapGeom(),
            accent: colors.accent,
          ),
        ),
      ),
    );
  }
}

class _EaglePainter extends CustomPainter {
  final ui.Image? image;
  final ({double dw, double dh, double rx, double ry, double wR, double hR, double nx, double ny}) geom;
  final Color accent;
  _EaglePainter({required this.image, required this.geom, required this.accent});

  @override
  void paint(Canvas canvas, Size size) {
    final img = image;
    if (img == null) return;
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, size.height));
    // 整图缩略
    final src = Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
    final dst = Rect.fromLTWH(geom.rx, geom.ry, geom.dw, geom.dh);
    canvas.drawImageRect(
      img,
      src,
      dst,
      Paint()..filterQuality = FilterQuality.low,
    );
    // 当前视野框（对应 .img-map-win）
    final vw = geom.wR * geom.dw;
    final vh = geom.hR * geom.dh;
    final cx = geom.rx + geom.nx * geom.dw;
    final cy = geom.ry + geom.ny * geom.dh;
    final rect = Rect.fromLTWH(cx - vw / 2, cy - vh / 2, vw, vh);
    canvas.drawRect(rect, Paint()..color = accent.withAlpha(38));
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = accent,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_EaglePainter old) =>
      old.geom != geom || old.image != image || old.accent != accent;
}