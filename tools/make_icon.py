#!/usr/bin/env python3
"""生成 Dockolate 的 app 图标（Dockolate.icns）。

设计：一个「内存池」框，里面三根高度不同的柱子（= 池里驻留的模型占多少）。
  · 元素只用两个：池框 + 三根柱 —— 小到 32px 也能认出「池子里有东西」
  · 深色渐变底 + macOS 图标圆角（22.37%），内容留边距不贴边
  · 柱顶微高光，避免看起来是死色块

用法：python3 tools/make_icon.py [--out build/icon]
产出：<out>/Dockolate.icns + <out>/preview-1024.png
"""
import os
import random
import subprocess
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 4096                 # 超采样画布
FINAL = 1024
RADIUS_RATIO = 0.2237    # Apple 图标圆角

BG_TOP = (26, 40, 57)
BG_BOT = (10, 16, 24)

COL_BLUE = (74, 152, 255)
COL_TEAL = (48, 206, 190)
COL_VIOLET = (162, 136, 250)

RESAMPLE = getattr(Image, "Resampling", Image).LANCZOS


def px(v: float) -> int:
    return int(round(v * S / FINAL))


def main() -> int:
    out_dir = "build/icon"
    argv = sys.argv[1:]
    if "--out" in argv:
        out_dir = argv[argv.index("--out") + 1]
    os.makedirs(out_dir, exist_ok=True)

    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # ---- 底：暖暗调 ----
    bg = Image.new("RGB", (1, S))
    for y in range(S):
        t = y / (S - 1)
        bg.putpixel((0, y), (int(32 + (14 - 32) * t),
                             int(20 + (9 - 20) * t),
                             int(11 + (5 - 11) * t)))
    bg = bg.resize((S, S))
    halo = Image.new("L", (S, S), 0)
    ImageDraw.Draw(halo).ellipse([px(-180), px(-280), px(900), px(720)], fill=52)
    halo = halo.filter(ImageFilter.GaussianBlur(px(180)))
    bg = Image.composite(Image.new("RGB", (S, S), (110, 66, 36)), bg, halo)

    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1],
                                           radius=int(S * RADIUS_RATIO), fill=255)
    img.paste(bg, (0, 0), mask)

    # ---- 几何：一整块，3×2，凹槽只是压痕 ----
    cols, rows = 3, 2
    bx0, by0 = px(130), px(190)
    bw, bh = S - bx0 * 2, px(644)
    bx1, by1 = bx0 + bw, by0 + bh
    groove = px(14)
    cw = (bw - groove * (cols - 1)) / cols
    ch = (bh - groove * (rows - 1)) / rows
    radius_out = px(56)
    hot = (1, 0)              # 琥珀格：第二行最左

    # 整块的圆角遮罩（后面所有操作都裁在它里面）
    board_mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(board_mask).rounded_rectangle([bx0, by0, bx1, by1],
                                                 radius=radius_out, fill=255)

    # 投影
    shadow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(shadow).rounded_rectangle(
        [bx0 - px(4), by0 + px(10), bx1 + px(4), by1 + px(20)],
        radius=radius_out, fill=140)
    shadow = shadow.filter(ImageFilter.GaussianBlur(px(28)))
    img.paste((0, 0, 0), (0, 0), shadow.point(lambda v: int(v * 0.62)))

    # ---- 整块本体：竖直渐变（牛奶巧克力）----
    strip = Image.new("RGB", (1, S))
    for i in range(S):
        t = i / (S - 1)
        strip.putpixel((0, i), (int(128 + (60 - 128) * t),
                                int(80 + (36 - 80) * t),
                                int(48 + (20 - 48) * t)))
    body = strip.resize((S, S))
    img.paste(body, (0, 0), board_mask)

    # ---- 琥珀格：直接在整块上染色（不是另画一块）----
    hx0 = bx0 + hot[1] * (cw + groove)
    hy0 = by0 + hot[0] * (ch + groove)
    hot_strip = Image.new("RGB", (1, S))
    for i in range(S):
        t = i / (S - 1)
        hot_strip.putpixel((0, i), (int(196 + (132 - 196) * t),
                                    int(146 + (84 - 146) * t),
                                    int(84 + (32 - 84) * t)))
    hot_img = hot_strip.resize((S, S))
    hot_mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(hot_mask).rectangle([hx0, hy0, hx0 + cw, hy0 + ch], fill=255)
    hot_mask = ImageChops.multiply(hot_mask, board_mask)
    img.paste(hot_img, (0, 0), hot_mask)

    # ---- 表面微纹理：可可的哑光颗粒 ----
    grain = Image.effect_noise((S, S), 26).convert("L")
    grain = grain.point(lambda v: int(abs(v - 128) * 0.55))
    dark = Image.new("RGB", (S, S), (0, 0, 0))
    img.paste(dark, (0, 0), ImageChops.multiply(grain, board_mask).point(lambda v: int(v * 0.95)))

    # ---- 凹槽：做成「真的凹陷」而不是画两条线 ----
    #   槽左壁背光（最暗）→ 槽底 → 槽右壁受光（亮）→ 紧贴槽口一圈 AO
    d = ImageDraw.Draw(img, "RGBA")
    gw = groove

    def draw_groove_v(gx: float):
        d.rectangle([gx - gw / 2, by0, gx + gw / 2, by1], fill=(12, 7, 3, 250))
        # 左壁：更深的窄条（背光）
        d.rectangle([gx - gw / 2, by0, gx - gw / 2 + gw * 0.34, by1], fill=(8, 4, 2, 255))
        # 右壁：受光的窄条
        d.rectangle([gx + gw * 0.10, by0, gx + gw / 2, by1], fill=(96, 60, 34, 235))
        # 槽口高光：贴着右沿的一线
        d.rectangle([gx + gw / 2 - px(2.4), by0, gx + gw / 2, by1], fill=(206, 152, 100, 175))
        # 两侧 AO
        d.rectangle([gx - gw / 2 - px(7), by0, gx - gw / 2, by1], fill=(0, 0, 0, 55))
        d.rectangle([gx + gw / 2, by0, gx + gw / 2 + px(6), by1], fill=(0, 0, 0, 42))

    def draw_groove_h(gy: float):
        d.rectangle([bx0, gy - gw / 2, bx1, gy + gw / 2], fill=(12, 7, 3, 250))
        d.rectangle([bx0, gy - gw / 2, bx1, gy - gw / 2 + gw * 0.34], fill=(8, 4, 2, 255))
        d.rectangle([bx0, gy + gw * 0.10, bx1, gy + gw / 2], fill=(96, 60, 34, 235))
        d.rectangle([bx0, gy + gw / 2 - px(2.4), bx1, gy + gw / 2], fill=(206, 152, 100, 175))
        d.rectangle([bx0, gy - gw / 2 - px(7), bx1, gy - gw / 2], fill=(0, 0, 0, 55))
        d.rectangle([bx0, gy + gw / 2, bx1, gy + gw / 2 + px(6)], fill=(0, 0, 0, 42))

    for c in range(1, cols):
        draw_groove_v(bx0 + c * cw + (c - 0.5) * gw)
    for r in range(1, rows):
        draw_groove_h(by0 + r * ch + (r - 0.5) * gw)

    # ---- 斜向油光：整块一次，不按格 ----
    sheen = Image.new("L", (S, S), 0)
    ImageDraw.Draw(sheen).polygon(
        [(bx0 - px(40), by1 - px(20)), (bx0 + px(170), by0 - px(60)),
         (bx0 + px(470), by0 - px(60)), (bx0 + px(260), by1 - px(20))],
        fill=255)
    sheen = sheen.filter(ImageFilter.GaussianBlur(px(62)))
    sheen = ImageChops.multiply(sheen, board_mask)
    img.alpha_composite(Image.composite(
        Image.new("RGBA", (S, S), (255, 246, 226, 92)),
        Image.new("RGBA", (S, S), (0, 0, 0, 0)), sheen))

    # ---- 外轮廓：只在顶部一条极淡的受光（不加整圈描边，否则像贴纸）----
    top_light = Image.new("L", (S, S), 0)
    ImageDraw.Draw(top_light).rounded_rectangle(
        [bx0, by0, bx1, by0 + px(30)], radius=radius_out, fill=90)
    top_light = ImageChops.multiply(top_light.filter(ImageFilter.GaussianBlur(px(14))), board_mask)
    img.alpha_composite(Image.composite(
        Image.new("RGBA", (S, S), (255, 232, 198, 255)),
        Image.new("RGBA", (S, S), (0, 0, 0, 0)), top_light))

    # ---- 琥珀格边缘一圈很淡的暖光（提示“这块在工作”）----
    glow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(glow).rectangle([hx0, hy0, hx0 + cw, hy0 + ch], fill=170)
    glow = glow.filter(ImageFilter.GaussianBlur(px(26)))
    glow = ImageChops.multiply(glow, board_mask)
    img.alpha_composite(Image.composite(
        Image.new("RGBA", (S, S), (255, 198, 120, 70)),
        Image.new("RGBA", (S, S), (0, 0, 0, 0)), glow))

    # ---- 收尾 ----
    final = img.resize((FINAL, FINAL), RESAMPLE)
    preview = os.path.join(out_dir, "preview-1024.png")
    final.save(preview)

    iconset = os.path.join(out_dir, "Dockolate.iconset")
    os.makedirs(iconset, exist_ok=True)
    for size in (16, 32, 64, 128, 256, 512):
        for scale, suffix in ((1, ""), (2, "@2x")):
            n = size * scale
            img.resize((n, n), RESAMPLE).save(
                os.path.join(iconset, f"icon_{size}x{size}{suffix}.png"))
    icns = os.path.join(out_dir, "Dockolate.icns")
    r = subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print("iconutil 失败：", r.stderr, file=sys.stderr)
        return 1
    print(f"图标已生成：{icns}（预览 {preview}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
