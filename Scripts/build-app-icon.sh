#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MASTER="$ROOT_DIR/design/lumisync-app-icon.png"
ICONSET_DIR_NAME="LumiSync.iconset"
ICNS="$ROOT_DIR/Packaging/LumiSync/Resources/LumiSync.icns"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lumisync-icon.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

mkdir -p "$(dirname "$MASTER")" "$(dirname "$ICNS")"

python3 - "$TEMP_DIR/master-hi.png" <<'PY'
import binascii
import math
import struct
import sys
import zlib

output = sys.argv[1]
SCALE = 2
WIDTH = HEIGHT = 1024 * SCALE
CX = CY = WIDTH / 2.0
OUTER = 452.0 * SCALE

pixels = bytearray(WIDTH * HEIGHT * 4)

def clamp(value, low=0.0, high=1.0):
    return low if value < low else high if value > high else value

def smoothstep(edge0, edge1, value):
    t = clamp((value - edge0) / (edge1 - edge0))
    return t * t * (3.0 - 2.0 * t)

def rgba_at(x, y):
    dx = abs(x - CX)
    dy = abs(y - CY)
    q = (dx / OUTER) ** 4.5 + (dy / OUTER) ** 4.5
    shape_alpha = 1.0 - smoothstep(0.985, 1.015, q)
    if shape_alpha <= 0.0:
        return (0, 0, 0, 0)

    vertical = clamp((y - 80.0 * SCALE) / (880.0 * SCALE))
    top = (12.0, 27.0, 62.0)
    bottom = (30.0, 24.0, 38.0)
    r = top[0] * (1.0 - vertical) + bottom[0] * vertical
    g = top[1] * (1.0 - vertical) + bottom[1] * vertical
    b = top[2] * (1.0 - vertical) + bottom[2] * vertical

    blue_glow = math.exp(-(((x - CX) / (330.0 * SCALE)) ** 2 + ((y - 330.0 * SCALE) / (300.0 * SCALE)) ** 2))
    amber_glow = math.exp(-(((x - CX) / (330.0 * SCALE)) ** 2 + ((y - 760.0 * SCALE) / (300.0 * SCALE)) ** 2))
    r += 14.0 * amber_glow
    g += 12.0 * blue_glow + 5.0 * amber_glow
    b += 28.0 * blue_glow
    return (int(clamp(r, 0, 255)), int(clamp(g, 0, 255)), int(clamp(b, 0, 255)), int(255 * shape_alpha))

def blend(index, color, alpha):
    if alpha <= 0.0:
        return
    alpha = clamp(alpha)
    old_r, old_g, old_b, old_a = pixels[index:index + 4]
    source_a = alpha * 255.0
    destination_a = old_a / 255.0
    result_a = alpha + destination_a * (1.0 - alpha)
    if result_a <= 0.0:
        return
    pixels[index] = int((color[0] * alpha + old_r * destination_a * (1.0 - alpha)) / result_a)
    pixels[index + 1] = int((color[1] * alpha + old_g * destination_a * (1.0 - alpha)) / result_a)
    pixels[index + 2] = int((color[2] * alpha + old_b * destination_a * (1.0 - alpha)) / result_a)
    pixels[index + 3] = int(result_a * 255.0)

def inside_round_rect(x, y, left, top, right, bottom, radius):
    qx = max(left + radius - x, 0.0, x - (right - radius))
    qy = max(top + radius - y, 0.0, y - (bottom - radius))
    return qx * qx + qy * qy <= radius * radius

def rounded_rect(left, top, right, bottom, radius, fill, border=None, border_width=0.0):
    x0, x1 = int(left - radius - 2), int(right + radius + 2)
    y0, y1 = int(top - radius - 2), int(bottom + radius + 2)
    for y in range(max(0, y0), min(HEIGHT, y1 + 1)):
        for x in range(max(0, x0), min(WIDTH, x1 + 1)):
            if not inside_round_rect(x, y, left, top, right, bottom, radius):
                continue
            idx = (y * WIDTH + x) * 4
            edge = False
            if border is not None and border_width > 0:
                edge = not inside_round_rect(x, y, left + border_width, top + border_width, right - border_width, bottom - border_width, max(0, radius - border_width))
            blend(idx, border if edge and border else fill, 1.0)

def capsule(x, y, half_width, half_height, color, alpha):
    distance = math.sqrt((max(abs(x - CX) - half_width, 0.0)) ** 2 + (max(abs(y - CY) - half_height, 0.0)) ** 2)
    if distance <= 0.0:
        return 1.0
    return clamp(1.0 - distance / (2.0 * SCALE)) * alpha

for y in range(HEIGHT):
    for x in range(WIDTH):
        pixels[(y * WIDTH + x) * 4:(y * WIDTH + x + 1) * 4] = bytes(rgba_at(x, y))

# A restrained inner display: blue, legible, and not a second app icon.
rounded_rect(205 * SCALE, 184 * SCALE, 819 * SCALE, 493 * SCALE, 52 * SCALE,
             (25, 48, 91, 255), (101, 177, 255, 255), 5 * SCALE)
rounded_rect(226 * SCALE, 205 * SCALE, 798 * SCALE, 472 * SCALE, 34 * SCALE,
             (10, 25, 58, 255), (47, 101, 176, 255), 3 * SCALE)
for y in range(220 * SCALE, 455 * SCALE):
    tint = 1.0 - (y - 220 * SCALE) / (235 * SCALE)
    for x in range(241 * SCALE, 783 * SCALE):
        idx = (y * WIDTH + x) * 4
        blend(idx, (20 + int(15 * tint), 52 + int(45 * tint), 112 + int(70 * tint)), 0.11)

# Minimal keyboard slab and three rows of amber-edged keys.
rounded_rect(176 * SCALE, 638 * SCALE, 848 * SCALE, 878 * SCALE, 44 * SCALE,
             (43, 35, 43, 255), (193, 126, 78, 255), 5 * SCALE)
rounded_rect(193 * SCALE, 655 * SCALE, 831 * SCALE, 859 * SCALE, 31 * SCALE,
             (24, 28, 40, 255), (105, 77, 65, 255), 3 * SCALE)
rows = [
    (222, 694, 64, 44, 8),
    (208, 748, 78, 48, 7),
    (194, 806, 101, 43, 6),
]
for row, (start_x, top, key_w, key_h, gap) in enumerate(rows):
    count = 8 if row == 0 else 7 if row == 1 else 6
    for key in range(count):
        left = (start_x + key * (key_w + gap)) * SCALE
        right = left + key_w * SCALE
        bottom = top * SCALE + key_h * SCALE
        rounded_rect(left, top * SCALE, right, bottom, 9 * SCALE,
                     (32, 31, 42, 255), (199, 128, 74, 255), 3 * SCALE)
        # A low amber key reflection, without text or glyphs.
        rounded_rect(left + 5 * SCALE, top * SCALE + 5 * SCALE,
                     right - 5 * SCALE, bottom - 7 * SCALE, 5 * SCALE,
                     (112, 69, 43, 255), None, 0)

# One continuous synchronization light, blue at the display and amber at the keyboard.
path = []
for i in range(81):
    t = i / 80.0
    u = 1.0 - t
    x = (512.0 * u**3 + 674.0 * 3 * u**2 * t + 344.0 * 3 * u * t**2 + 512.0 * t**3) * SCALE
    y = (465.0 * u**3 + 515.0 * 3 * u**2 * t + 604.0 * 3 * u * t**2 + 700.0 * t**3) * SCALE
    path.append((x, y, t))
for y in range(445 * SCALE, 720 * SCALE):
    for x in range(320 * SCALE, 705 * SCALE):
        nearest = None
        for (x0, y0, t0), (x1, y1, t1) in zip(path, path[1:]):
            vx, vy = x1 - x0, y1 - y0
            length_sq = vx * vx + vy * vy
            projection = clamp(((x - x0) * vx + (y - y0) * vy) / length_sq)
            px, py = x0 + projection * vx, y0 + projection * vy
            distance = math.hypot(x - px, y - py)
            if nearest is None or distance < nearest[0]:
                nearest = (distance, t0 + projection * (t1 - t0))
        distance, t = nearest
        if distance > 28 * SCALE:
            continue
        blue = (63, 190, 255)
        amber = (255, 174, 76)
        color = tuple(int(blue[i] * (1.0 - t) + amber[i] * t) for i in range(3))
        glow = math.exp(-((distance / (18.0 * SCALE)) ** 2))
        core = math.exp(-((distance / (5.0 * SCALE)) ** 2))
        idx = (y * WIDTH + x) * 4
        blend(idx, color, 0.28 * glow)
        core_color = tuple(int((84, 220, 255)[i] * (1.0 - t) + (255, 178, 68)[i] * t) for i in range(3))
        blend(idx, core_color, 0.72 * core)

# Re-apply the silhouette alpha so every element remains clipped to the native squircle.
for y in range(HEIGHT):
    for x in range(WIDTH):
        dx = abs(x - CX)
        dy = abs(y - CY)
        q = (dx / OUTER) ** 4.5 + (dy / OUTER) ** 4.5
        alpha = 1.0 - smoothstep(0.985, 1.015, q)
        if alpha < 1.0:
            idx = (y * WIDTH + x) * 4
            pixels[idx + 3] = int(pixels[idx + 3] * alpha)
            if pixels[idx + 3] == 0:
                pixels[idx:idx + 3] = b"\x00\x00\x00"

def chunk(kind, data):
    return (struct.pack(">I", len(data)) + kind + data +
            struct.pack(">I", binascii.crc32(kind + data) & 0xFFFFFFFF))

raw = bytearray()
for y in range(HEIGHT):
    raw.append(0)
    raw.extend(pixels[y * WIDTH * 4:(y + 1) * WIDTH * 4])
png = bytearray(b"\x89PNG\r\n\x1a\n")
png.extend(chunk(b"IHDR", struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 6, 0, 0, 0)))
png.extend(chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
png.extend(chunk(b"IEND", b""))
with open(output, "wb") as handle:
    handle.write(png)
PY

sips -z 1024 1024 "$TEMP_DIR/master-hi.png" --out "$MASTER" >/dev/null

ICONSET="$TEMP_DIR/$ICONSET_DIR_NAME"
mkdir -p "$ICONSET"
while IFS=' ' read -r size name; do
    sips -z "$size" "$size" "$MASTER" --out "$ICONSET/$name" >/dev/null
done <<'SIZES'
16 icon_16x16.png
32 icon_16x16@2x.png
32 icon_32x32.png
64 icon_32x32@2x.png
128 icon_128x128.png
256 icon_128x128@2x.png
256 icon_256x256.png
512 icon_256x256@2x.png
512 icon_512x512.png
1024 icon_512x512@2x.png
SIZES

iconutil -c icns "$ICONSET" -o "$TEMP_DIR/LumiSync.icns"
mv "$TEMP_DIR/LumiSync.icns" "$ICNS"

python3 "$ROOT_DIR/Scripts/verify-app-icon.py" --master "$MASTER" --icns "$ICNS"
