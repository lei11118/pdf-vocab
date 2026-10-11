#!/usr/bin/env python3
"""生成 1024x1024 App 图标(纯标准库,零依赖):
蓝紫渐变背景 + 白色圆角"书页" + 文字行 + 黄色高亮条。输出 RGB PNG(无 alpha)。
用法: python make_icon.py <输出路径>
"""
import struct
import sys
import zlib

W = 1024
SS = 2  # 超采样倍数
w = W * SS

buf = bytearray(w * w * 3)

# ---------- 背景渐变(左上 #1d4ed8 → 右下 #7c3aed,按 x+y 查表) ----------
c0 = (29, 78, 216)
c1 = (124, 58, 237)
grad = []
for s in range(2 * w - 1):
    t = s / (2 * w - 2)
    grad.append(tuple(round(c0[i] + (c1[i] - c0[i]) * t) for i in range(3)))
for y in range(w):
    base = y * w
    for x in range(w):
        r, g, b = grad[x + y]
        i = (base + x) * 3
        buf[i] = r
        buf[i + 1] = g
        buf[i + 2] = b


def blend_px(x, y, color, a=1.0):
    if x < 0 or y < 0 or x >= w or y >= w:
        return
    i = (y * w + x) * 3
    if a >= 1.0:
        buf[i] = color[0]
        buf[i + 1] = color[1]
        buf[i + 2] = color[2]
    else:
        buf[i] = round(buf[i] * (1 - a) + color[0] * a)
        buf[i + 1] = round(buf[i + 1] * (1 - a) + color[1] * a)
        buf[i + 2] = round(buf[i + 2] * (1 - a) + color[2] * a)


def rrect(x0, y0, x1, y1, rad, color, a=1.0):
    for y in range(int(y0), int(y1) + 1):
        for x in range(int(x0), int(x1) + 1):
            dx = 0.0
            dy = 0.0
            if x < x0 + rad:
                dx = (x0 + rad) - x
            elif x > x1 - rad:
                dx = x - (x1 - rad)
            if y < y0 + rad:
                dy = (y0 + rad) - y
            elif y > y1 - rad:
                dy = y - (y1 - rad)
            if dx and dy and (dx * dx + dy * dy) > rad * rad:
                continue
            blend_px(x, y, color, a)


U = lambda v: int(round(v * w))  # 比例坐标 → 画布像素

# 投影
rrect(U(0.16) + 14, U(0.135) + 18, U(0.84) + 14, U(0.865) + 18, U(0.075), (20, 12, 70), 0.35)
# 书页
rrect(U(0.16), U(0.135), U(0.84), U(0.865), U(0.075), (255, 255, 255))
# 书脊
rrect(U(0.215), U(0.20), U(0.235), U(0.80), U(0.010), (96, 150, 250))
# 文字行(灰)
rrect(U(0.285), U(0.245), U(0.735), U(0.295), U(0.025), (222, 226, 233))
rrect(U(0.285), U(0.355), U(0.665), U(0.405), U(0.025), (222, 226, 233))
# 高亮行(黄)
rrect(U(0.285), U(0.465), U(0.760), U(0.515), U(0.025), (250, 204, 21))
# 文字行(灰)
rrect(U(0.285), U(0.575), U(0.585), U(0.625), U(0.025), (222, 226, 233))
rrect(U(0.285), U(0.685), U(0.680), U(0.735), U(0.025), (222, 226, 233))

# ---------- 下采样(SS x SS 平均) ----------
out = bytearray(W * W * 3)
for y in range(W):
    for x in range(W):
        o = (y * W + x) * 3
        r = g = b = 0
        for dy in range(SS):
            row = (y * SS + dy) * w
            for dx in range(SS):
                i = (row + (x * SS + dx)) * 3
                r += buf[i]
                g += buf[i + 1]
                b += buf[i + 2]
        n = SS * SS
        out[o] = r // n
        out[o + 1] = g // n
        out[o + 2] = b // n


# ---------- 写 PNG(color type 2: RGB,无 alpha) ----------
def chunk(tag, data):
    return (
        struct.pack(">I", len(data))
        + tag
        + data
        + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    )


raw = bytearray()
for y in range(W):
    raw.append(0)
    raw += out[y * W * 3 : (y + 1) * W * 3]

png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", W, W, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
png += chunk(b"IEND", b"")

path = sys.argv[1] if len(sys.argv) > 1 else "icon-1024.png"
with open(path, "wb") as f:
    f.write(png)
print("written:", path, len(png), "bytes")
