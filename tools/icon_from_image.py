#!/usr/bin/env python3
"""把一张方形 AI 出图做成 macOS 图标（居中裁切 + 圆角 + icns）。

用法：python3 tools/icon_from_image.py <源图> [输出目录] [--zoom=0.86] [--name=Dockolate] [--variant=dock|hub]
默认输出 build/icon/{preview-1024.png, Dockolate.icns}

--variant 决定 16/32px 的剪影画法：
  dock（默认）→ 四格里左上格点亮（Dockolate 的身份）
  hub        → 四格同色 + 中心一枚琥珀圆点（DockolateHub 的身份：中枢在正中）

优先关系（见 build.sh）：
  resources/icon-source.png 存在 → 用本脚本把它做成图标
  否则 → 用 tools/make_icon.py 程序化生成（无外部素材时的兜底）
"""
import os
import subprocess
import sys

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter, ImageOps

FINAL = 1024
RADIUS_RATIO = 0.2237    # Apple 图标圆角
VARIANT = "dock"
BLEED = False            # True = 四格顶满图标（--crop 时自动打开）


def rounded_mask(size: int, radius_ratio: float = RADIUS_RATIO, ss: int = 4) -> Image.Image:
    """抗锯齿的圆角遮罩：在 ss 倍画布上画，再缩回来。

    直接在小画布上 fill=255 得到的是硬边（台阶），放大看就是「圆角不圆、边缘发毛」；
    缩样后 alpha 才是连续过渡，边缘才干净。
    """
    big = size * ss
    m = Image.new("L", (big, big), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, big - 1, big - 1],
                                       radius=int(big * radius_ratio), fill=255)
    return m.resize((size, size), Image.LANCZOS)


def apply_chamfer(im: Image.Image, width_ratio: float = 0.032, angle_deg: float = 52.0) -> Image.Image:
    """按「圆角矩形 SDF + 法线光照」画内收倒角（v3）。

    v1/v2 的问题：用「一圈亮带 + 斜向渐变」近似倒角，四角的亮度只跟 x+y 有关，
    所以左上角过亮、右下角过暗且发虚，四个角看起来不像同一块料。
    现在改成真几何：先算圆角矩形的有符号距离场，边缘 W 像素内把表面法线
    从「朝上」逐渐转到「朝外」（= 斜边），再用一束左上方的平行光算法线光照
    （漫反射 + Blinn 高光）。四个角自然一致，斜边也跟着圆角真正地转下去。
    """
    import numpy as np

    S = im.size[0]
    R = int(S * RADIUS_RATIO)
    W = max(6.0, S * width_ratio)
    c = S / 2.0

    axis = np.arange(S, dtype=np.float32) + 0.5 - c
    X, Y = np.meshgrid(axis, axis)
    qx = np.abs(X) - (c - R)
    qy = np.abs(Y) - (c - R)
    d = np.minimum(np.maximum(qx, qy), 0.0) + np.sqrt(
        np.maximum(qx, 0.0) ** 2 + np.maximum(qy, 0.0) ** 2) - R   # <0 在图标内部

    s = np.clip(-d / W, 0.0, 1.0)          # 1 = 最外沿，0 = 斜边以内
    gy, gx = np.gradient(-d)               # 指向外侧的 2D 法线
    n = np.hypot(gx, gy)
    n[n < 1e-6] = 1.0
    nx, ny = gx / n, gy / n

    a = np.deg2rad(angle_deg) * s          # 斜边倾角：由平面渐变到斜面
    NX, NY, NZ = nx * np.sin(a), ny * np.sin(a), np.cos(a)

    L = np.array([-0.42, -0.52, 0.74], dtype=np.float32)
    L /= np.linalg.norm(L)                 # 左上方平行光
    diff = np.clip(NX * L[0] + NY * L[1] + NZ * L[2], 0.0, 1.0)
    Hh = L + np.array([0, 0, 1.0], dtype=np.float32)
    Hh /= np.linalg.norm(Hh)
    spec = np.clip(NX * Hh[0] + NY * Hh[1] + NZ * Hh[2], 0.0, 1.0) ** 26

    ramp = (diff - L[2]) * (s > 0.0)       # 相对「平面」的明暗变化
    mult = 1.0 + ramp * 1.10 - (s ** 2) * 0.12   # 受光侧提亮 / 背光侧压暗 / 最外沿收一圈
    mult = np.clip(mult, 0.35, 1.6)
    spec_add = (spec * (s ** 1.2) * 0.45)[..., None] * np.array([255, 238, 206], dtype=np.float32)

    rgb = np.asarray(im.convert("RGB"), dtype=np.float32) * mult[..., None] + spec_add
    out = Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8), "RGB")
    out = out.filter(ImageFilter.GaussianBlur(0.7))      # 抹掉色阶，但边缘仍靠 alpha 保持锐利

    res = out.convert("RGBA")
    res.putalpha(im.split()[3])
    return res


def apply_bevel(im: Image.Image) -> Image.Image:
    """老版倒角（无 numpy 时的兜底）。

    用「一圈亮带 + 斜向渐变」近似，四角亮度只随 x+y 变化，效果不如 apply_chamfer，
    仅在没有 numpy 的环境里使用。
    """
    S = im.size[0]
    R = int(S * RADIUS_RATIO)

    def rr(k: int) -> Image.Image:
        m = Image.new("L", (S, S), 0)
        ImageDraw.Draw(m).rounded_rectangle([k, k, S - 1 - k, S - 1 - k],
                                           radius=max(0, R - k), fill=255)
        return m

    band = ImageChops.subtract(rr(0), rr(int(S * 0.038)))          # 边缘厚度区
    band = band.filter(ImageFilter.GaussianBlur(S * 0.009))        # 柔化，去掉描边感
    inner = ImageChops.subtract(rr(int(S * 0.020)), rr(int(S * 0.052)))
    inner = inner.filter(ImageFilter.GaussianBlur(S * 0.012))      # 斜面内侧的过渡

    trans = getattr(Image, "Transpose", Image)
    vert = ImageOps.invert(Image.linear_gradient("L")).resize((S, S), Image.BILINEAR)  # 顶亮底暗
    horiz = vert.transpose(trans.ROTATE_270)                       # 左亮右暗
    light = ImageChops.add(vert, horiz, scale=2.0)                 # 斜向光照 左上1 → 右下0
    dark_dir = ImageChops.invert(light)

    overlay = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    warm = (255, 240, 214)
    # 1) 受光侧：板边转上来的一圈暖高光（宽而软）
    lit = ImageChops.multiply(band, light).point(lambda v: int(v * 0.34))
    overlay.paste(Image.new("RGBA", (S, S), warm + (255,)), (0, 0), lit)
    # 2) 背光侧：边缘压暗，坐实厚度
    dark = ImageChops.multiply(band, dark_dir).point(lambda v: int(v * 0.55))
    overlay.paste(Image.new("RGBA", (S, S), (0, 0, 0, 255)), (0, 0), dark)
    # 3) 斜面与台面之间再压一道很轻的过渡（只在背光侧）
    dark2 = ImageChops.multiply(inner, dark_dir).point(lambda v: int(v * 0.22))
    overlay.paste(Image.new("RGBA", (S, S), (0, 0, 0, 255)), (0, 0), dark2)

    out = im.copy()
    out.alpha_composite(overlay)
    return out


def render_small(n: int) -> Image.Image:
    """16/32px 专用：写实图在这个尺寸一定会糊成一团棕，改成纯剪影。

    保留小尺寸还能读的信息：圆角底 + 2×2 分格 + 一个身份色块。
    刻意不放字母——32px 下一格只有十几像素，字母必然是噪点。
    dock：左上格点亮；hub：四格同色 + 正中一枚琥珀圆点（中枢）。
    """
    im = Image.new("RGBA", (n, n), (12, 7, 3, 255))   # 缝隙色要够深，否则小尺寸糊成一片
    d = ImageDraw.Draw(im)
    if BLEED:
        # 顶满图标：四格直接贴到圆角边，只留一根缝的宽度
        pad = max(0, round(n * 0.012))
    else:
        pad = max(1, round(n * 0.07))
    gap = max(1, round(n * 0.065))                    # 缝略宽，16px 才分得开
    cell = (n - pad * 2 - gap) / 2
    radius = max(1, round(cell * 0.22))
    amber = (218, 156, 88, 255)
    for r in range(2):
        for c in range(2):
            x0 = pad + c * (cell + gap)
            y0 = pad + r * (cell + gap)
            if VARIANT == "hub":
                color = (146, 92, 56, 255)            # 四格同色：身份在中心，不在格子
            else:
                # 高亮格必须与写实版一致：左上（C 那格），否则尺寸切换时视觉焦点会跳
                color = amber if (r, c) == (0, 0) else (146, 92, 56, 255)
            d.rounded_rectangle([x0, y0, x0 + cell, y0 + cell], radius=radius, fill=color)
    if VARIANT == "hub":
        # 中心接点：直径约 0.46 个格子，16px 下也能看见一个亮点
        cr = max(1.2, cell * 0.23)
        cx = cy = n / 2
        d.ellipse([cx - cr, cy - cr, cx + cr, cy + cr], fill=amber)
    im.putalpha(squircle_mask(n, ss=8))
    return im


def squircle_mask(size: int, ss: int = 4, exponent: float = 5.0, inset: float = 0.0) -> Image.Image:
    """macOS 图标本体形状：超椭圆（squircle），不是普通的圆角矩形。

    Apple 的图标轮廓是连续曲率的超椭圆，|x|^n + |y|^n = 1（n≈5）；用
    rounded_rectangle 画出来四角会显得「方」一点，正是「圆角不像 macOS」的来源。
    这里按参数方程采样成多边形，再在 ss 倍画布上填充，缩回来即抗锯齿。
    """
    import math
    big = size * ss
    a = big / 2.0 * (1.0 - inset)
    pts = []
    steps = 2048
    for i in range(steps):
        t = 2.0 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = math.copysign(abs(ct) ** (2.0 / exponent), ct)
        y = math.copysign(abs(st) ** (2.0 / exponent), st)
        pts.append((big / 2.0 + x * a, big / 2.0 + y * a))
    m = Image.new("L", (big, big), 0)
    ImageDraw.Draw(m).polygon(pts, fill=255)
    return m.resize((size, size), Image.LANCZOS)


def trim_to_body(im: Image.Image, size: int) -> Image.Image:
    """把「画在白底上、自带圆角」的图标裁到本体轮廓并缩放到 size。

    用途：让出图模型按 macOS 图标规范自己把圆角和倒角画进图里（--trim），
    我们只负责把本体抠出来对齐到 1024 —— 不再程序化加倒角，避免和模型的画法打架。
    判据：明显比白底暗的像素 = 本体；投影很淡，阈值取 200 就能避开。
    """
    gray = im.convert("L")
    mask = gray.point(lambda v: 255 if v < 200 else 0)
    box = mask.getbbox()
    if not box:
        return im.resize((size, size), Image.LANCZOS)
    x0, y0, x1, y1 = box
    # 白底图上，括号边缘常常还有 1~3 px 接近纯白的描边/残影：向内收到不再发白为止，
    # 否则贴好遮罩后会出现一圈白边
    px = gray.load()
    def ring_mean(x0, y0, x1, y1):
        vals = []
        for x in range(x0, x1, max(1, (x1 - x0) // 64)):
            vals += [px[x, y0], px[x, y1 - 1]]
        for y in range(y0, y1, max(1, (y1 - y0) // 64)):
            vals += [px[x0, y], px[x1 - 1, y]]
        return sum(vals) / max(1, len(vals))
    inset = 0
    while inset < 40 and x1 - x0 > 32 and y1 - y0 > 32 and ring_mean(x0, y0, x1, y1) > 215:
        x0 += 1; y0 += 1; x1 -= 1; y1 -= 1; inset += 1
    # 取**较小**的那条边做正方形：宁可往里收几像素，也不要把白底带进来
    side = min(x1 - x0, y1 - y0)
    cx, cy = (x0 + x1) / 2.0, (y0 + y1) / 2.0
    W, H = im.size
    left = min(max(cx - side / 2.0, 0), W - side)
    top = min(max(cy - side / 2.0, 0), H - side)
    return im.crop((int(round(left)), int(round(top)),
                    int(round(left + side)), int(round(top + side)))).resize((size, size), Image.LANCZOS)


def main() -> int:
    global VARIANT, BLEED
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    src = sys.argv[1]
    out_dir = sys.argv[2] if len(sys.argv) > 2 and not sys.argv[2].startswith("--") else "build/icon"
    zoom = 0.86          # 裁掉多少边缘：越小主体越大、留白越少（--crop 给了就不用它）
    name = "Dockolate"   # icns / iconset 基名
    TRIM = False         # --trim：图里已经自带圆角+倒角，只抠本体对齐
    crop = None          # --crop=L,T,R,B（百分比），直接框住巧克力板、顶满图标
    for a in sys.argv[1:]:
        if a.startswith("--zoom="):
            zoom = float(a.split("=", 1)[1])
        elif a.startswith("--name="):
            name = a.split("=", 1)[1]
        elif a.startswith("--variant="):
            VARIANT = a.split("=", 1)[1]
        elif a == "--trim":
            TRIM = True
        elif a.startswith("--crop="):
            crop = [float(v) / 100.0 for v in a.split("=", 1)[1].split(",")]
            if len(crop) != 4:
                print("--crop 需要 L,T,R,B 四个百分比", file=sys.stderr)
                return 2
            BLEED = True
    os.makedirs(out_dir, exist_ok=True)

    im = Image.open(src).convert("RGBA")
    w, h = im.size
    if TRIM:
        im = trim_to_body(im, FINAL)
    elif crop is not None:
        l, t, r, b = crop
        x0, y0, x1, y1 = l * w, t * h, r * w, b * h
        # 不是正方形就先扩成正方形（以框中心为准，不拉伸变形）
        bw, bh = x1 - x0, y1 - y0
        side = max(bw, bh)
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        x0, y0 = cx - side / 2, cy - side / 2
        # 越界就把框整体推回画面内
        x0 = min(max(0.0, x0), w - side)
        y0 = min(max(0.0, y0), h - side)
        side = min(side, w, h)
        im = im.crop((int(round(x0)), int(round(y0)),
                      int(round(x0 + side)), int(round(y0 + side))))
        im = im.resize((FINAL, FINAL), Image.LANCZOS)
    else:
        side = min(w, h)
        im = im.crop(((w - side) // 2, (h - side) // 2,
                      (w - side) // 2 + side, (h - side) // 2 + side))
        im = im.resize((FINAL, FINAL), Image.LANCZOS)

        # 主体放大：从中心再裁一圈（用户要求留白更少）
        z = int(FINAL * zoom)
        off = (FINAL - z) // 2
        im = im.crop((off, off, off + z, off + z)).resize((FINAL, FINAL), Image.LANCZOS)

    # 柔和暗角：把四角压暗一点，让巧克力主体从同色背景里分离出来
    # （--crop 顶满画面时不再压角：四角已经是巧克力本体，压暗会脏）
    if crop is None and not TRIM:
        vig = Image.new("L", (FINAL, FINAL), 0)
        vd = ImageDraw.Draw(vig)
        vd.ellipse([-int(FINAL * 0.18), -int(FINAL * 0.18),
                    int(FINAL * 1.18), int(FINAL * 1.18)], fill=255)
        vig = vig.filter(__import__("PIL.ImageFilter", fromlist=["ImageFilter"]).GaussianBlur(FINAL * 0.10))
        dark = Image.new("RGBA", (FINAL, FINAL), (26, 14, 8, 255))
        im = Image.composite(im, Image.blend(im, dark, 0.42), vig)

    mask = squircle_mask(FINAL)      # macOS 图标本体是超椭圆，不是圆角矩形
    im.putalpha(mask)

    # 顶满（--crop）时给边缘加一圈内收倒角：按 SDF 做法线光照（无 numpy 时退回老版）
    if BLEED:
        try:
            im = apply_chamfer(im)
        except ImportError:
            im = apply_bevel(im)

    preview = os.path.join(out_dir, f"preview-{name}-1024.png")
    im.save(preview)

    iconset = os.path.join(out_dir, f"{name}.iconset")
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
    icns = os.path.join(out_dir, f"{name}.icns")
    r = subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print("iconutil 失败：", r.stderr, file=sys.stderr)
        return 1
    print(f"图标已生成：{icns}（源 {src}，预览 {preview}，variant={VARIANT}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
