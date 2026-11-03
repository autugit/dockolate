#!/usr/bin/env python3
"""把一张方形 AI 出图做成 macOS 图标（居中裁切 + 圆角 + icns）。

用法：python3 tools/icon_from_image.py <源图> [输出目录]
默认输出 build/icon/{preview-1024.png, Dockolate.icns}

优先关系（见 build.sh）：
  resources/icon-source.png 存在 → 用本脚本把它做成图标
  否则 → 用 tools/make_icon.py 程序化生成（无外部素材时的兜底）
"""
import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

FINAL = 1024
RADIUS_RATIO = 0.2237    # Apple 图标圆角


def render_small(n: int) -> Image.Image:
    """16/32px 专用：写实图在这个尺寸一定会糊成一团棕，改成纯剪影。

    保留三件小尺寸还能读的信息：圆角底、2×2 分格、其中一格是亮的（琥珀）。
    刻意不放字母——32px 下一格只有十几像素，字母必然是噪点。
    """
    im = Image.new("RGBA", (n, n), (12, 7, 3, 255))   # 缝隙色要够深，否则小尺寸糊成一片
    d = ImageDraw.Draw(im)
    pad = max(1, round(n * 0.07))
    gap = max(1, round(n * 0.065))                    # 缝略宽，16px 才分得开
    cell = (n - pad * 2 - gap) / 2
    radius = max(1, round(cell * 0.22))
    for r in range(2):
        for c in range(2):
            x0 = pad + c * (cell + gap)
            y0 = pad + r * (cell + gap)
            # 高亮格必须与写实版一致：左上（C 那格），否则尺寸切换时视觉焦点会跳
            color = (218, 156, 88, 255) if (r, c) == (0, 0) else (146, 92, 56, 255)
            d.rounded_rectangle([x0, y0, x0 + cell, y0 + cell], radius=radius, fill=color)
    mask = Image.new("L", (n, n), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, n - 1, n - 1],
                                           radius=round(n * RADIUS_RATIO), fill=255)
    im.putalpha(mask)
    return im


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    src = sys.argv[1]
    out_dir = sys.argv[2] if len(sys.argv) > 2 else "build/icon"
    zoom = 0.86          # 裁掉多少边缘：越小主体越大、留白越少
    for a in sys.argv[1:]:
        if a.startswith("--zoom="):
            zoom = float(a.split("=", 1)[1])
    os.makedirs(out_dir, exist_ok=True)

    im = Image.open(src).convert("RGBA")
    w, h = im.size
    side = min(w, h)
    im = im.crop(((w - side) // 2, (h - side) // 2,
                  (w - side) // 2 + side, (h - side) // 2 + side))
    im = im.resize((FINAL, FINAL), Image.LANCZOS)

    # 主体放大：从中心再裁一圈（用户要求留白更少）
    z = int(FINAL * zoom)
    off = (FINAL - z) // 2
    im = im.crop((off, off, off + z, off + z)).resize((FINAL, FINAL), Image.LANCZOS)

    # 柔和暗角：把四角压暗一点，让巧克力主体从同色背景里分离出来
    vig = Image.new("L", (FINAL, FINAL), 0)
    vd = ImageDraw.Draw(vig)
    vd.ellipse([-int(FINAL * 0.18), -int(FINAL * 0.18),
                int(FINAL * 1.18), int(FINAL * 1.18)], fill=255)
    vig = vig.filter(__import__("PIL.ImageFilter", fromlist=["ImageFilter"]).GaussianBlur(FINAL * 0.10))
    dark = Image.new("RGBA", (FINAL, FINAL), (26, 14, 8, 255))
    im = Image.composite(im, Image.blend(im, dark, 0.42), vig)

    mask = Image.new("L", (FINAL, FINAL), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, FINAL - 1, FINAL - 1], radius=int(FINAL * RADIUS_RATIO), fill=255)
    im.putalpha(mask)

    preview = os.path.join(out_dir, "preview-1024.png")
    im.save(preview)

    iconset = os.path.join(out_dir, "Dockolate.iconset")
    os.makedirs(iconset, exist_ok=True)
    for size in (16, 32, 64, 128, 256, 512):
        for scale, suffix in ((1, ""), (2, "@2x")):
            n = size * scale
            if n <= 32:
                # 写实图缩到这个尺寸只会剩一团棕：换成立即能认的剪影
                render_small(n).save(os.path.join(iconset, f"icon_{size}x{size}{suffix}.png"))
                continue
            small = im.resize((n, n), Image.LANCZOS)
            # 小尺寸（≤64px）先提对比 + 锐化：写实图直接缩会糊成一团棕
            if n <= 64:
                from PIL import ImageEnhance, ImageFilter
                rgb = small.convert("RGB")
                rgb = ImageEnhance.Contrast(rgb).enhance(1.22)
                rgb = ImageEnhance.Color(rgb).enhance(1.06)
                rgb = rgb.filter(ImageFilter.UnsharpMask(radius=1.1, percent=120, threshold=2))
                small = rgb.convert("RGBA")
                small.putalpha(small.split()[3])
                # 重新贴回圆角 alpha（锐化不影响 alpha，但保险）
                small.putalpha(im.resize((n, n), Image.LANCZOS).split()[3])
            small.save(os.path.join(iconset, f"icon_{size}x{size}{suffix}.png"))
    icns = os.path.join(out_dir, "Dockolate.icns")
    r = subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print("iconutil 失败：", r.stderr, file=sys.stderr)
        return 1
    print(f"图标已生成：{icns}（源 {src}，预览 {preview}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
