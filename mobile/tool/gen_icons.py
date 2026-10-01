"""生成 Sylphplay 移动端应用图标（Android + iOS）。

源图：<项目根>/assets/icon.png（唯一真源，2048²，带透明留白）
原则：只做等比缩放，绝不裁切 / 重排 / 改动源图中的留白与构图。

产物：
  - Android 传统图标   res/mipmap-*/ic_launcher.png、ic_launcher_round.png
  - Android 自适应图标 res/mipmap-anydpi-v26/*.xml
                       res/drawable/ic_launcher_background.xml（白底）
                       res/mipmap-*/ic_launcher_foreground.png（源图原样，108dp）
  - iOS               ios/Runner/Assets.xcassets/AppIcon.appiconset/*（原文件名覆盖，白底，无透明）

用法：py tool/gen_icons.py
"""
import os
import re

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                       # mobile/
SRC = os.path.join(ROOT, '..', 'assets', 'icon.png')  # 项目根 assets/icon.png
RES = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res')
IOS = os.path.join(ROOT, 'ios', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')

SS = 4            # 超采样倍数（圆形遮罩抗锯齿用）
BACKDROP = (254, 254, 254, 255)   # 原始 SVG 底色 #FEFEFE

DENSITIES = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}

BG_XML = '''<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android"
    android:shape="rectangle">
    <solid android:color="#FEFEFE" />
</shape>
'''

ADAPTIVE_XML = '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
'''


def scaled(img, px):
    return img.resize((px, px), Image.LANCZOS)


def circle_alpha(px):
    m = Image.new('L', (px * SS, px * SS), 0)
    ImageDraw.Draw(m).ellipse((0, 0, px * SS - 1, px * SS - 1), fill=255)
    return m.resize((px, px), Image.LANCZOS)


def main():
    src = Image.open(SRC).convert('RGBA')
    print(f'source: {SRC}')
    print(f'        {src.size[0]}x{src.size[1]} {src.mode}')

    # ---- Android 传统图标 ----
    for name, scale in DENSITIES.items():
        d = os.path.join(RES, 'mipmap-' + name)
        os.makedirs(d, exist_ok=True)
        px = int(48 * scale)
        scaled(src, px).save(os.path.join(d, 'ic_launcher.png'))

        rnd = scaled(src, px)
        rnd.putalpha(circle_alpha(px))
        rnd.save(os.path.join(d, 'ic_launcher_round.png'))

        scaled(src, int(108 * scale)).save(os.path.join(d, 'ic_launcher_foreground.png'))
        print(f'android {name}: legacy={px} round={px} foreground={int(108 * scale)}')

    # ---- Android 自适应图标 ----
    dr = os.path.join(RES, 'drawable')
    os.makedirs(dr, exist_ok=True)
    with open(os.path.join(dr, 'ic_launcher_background.xml'), 'w', encoding='utf-8') as f:
        f.write(BG_XML)
    anydpi = os.path.join(RES, 'mipmap-anydpi-v26')
    os.makedirs(anydpi, exist_ok=True)
    for n in ('ic_launcher.xml', 'ic_launcher_round.xml'):
        with open(os.path.join(anydpi, n), 'w', encoding='utf-8') as f:
            f.write(ADAPTIVE_XML)
    print('android: adaptive icon xml written')

    # ---- iOS（按现有文件名解析尺寸覆盖；iOS 不允许透明，透明处填原底色）----
    pat = re.compile(r'^Icon-App-([\d.]+)x([\d.]+)@(\d)x\.png$')
    n = 0
    for fn in sorted(os.listdir(IOS)):
        m = pat.match(fn)
        if not m:
            continue
        w, h, s = float(m.group(1)), float(m.group(2)), int(m.group(3))
        assert abs(w - h) < 0.01, fn
        px = int(round(w * s))
        canvas = Image.new('RGBA', (px, px), BACKDROP)
        canvas.alpha_composite(scaled(src, px))
        canvas.convert('RGB').save(os.path.join(IOS, fn))
        n += 1
        print(f'ios {fn}: {px}')
    print(f'ios: {n} files')


if __name__ == '__main__':
    main()