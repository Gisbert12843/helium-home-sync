#!/usr/bin/env python3
import math
import os
import struct
import zlib

OUT = os.path.join(os.path.dirname(__file__), "..", "extension", "icons")
SS = 4

TOP = (0x6E, 0x6E, 0xF0)
BOTTOM = (0x4A, 0x4A, 0xC8)
WHITE = (255, 255, 255)


def inside_rounded_square(x, y, r):
    cx = min(max(x, r), 1 - r)
    cy = min(max(y, r), 1 - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def dist_to_segment(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def in_triangle(px, py, a, b, c):
    def sign(p1, p2, p3):
        return (p1[0] - p3[0]) * (p2[1] - p3[1]) - (p2[0] - p3[0]) * (p1[1] - p3[1])
    d1, d2, d3 = sign((px, py), a, b), sign((px, py), b, c), sign((px, py), c, a)
    neg = d1 < 0 or d2 < 0 or d3 < 0
    pos = d1 > 0 or d2 > 0 or d3 > 0
    return not (neg and pos)


def shade(x, y, size):
    if not inside_rounded_square(x, y, 0.22):
        return None
    cx, cy = 0.5, 0.5
    rad = 0.29
    stroke = 0.075 if size > 24 else 0.095
    d = math.hypot(x - cx, y - cy)
    ang = math.degrees(math.atan2(y - cy, x - cx)) % 360
    on_ring = abs(d - rad) <= stroke / 2 and not (285 <= ang <= 335)
    a_ang = math.radians(285)
    ex, ey = cx + rad * math.cos(a_ang), cy + rad * math.sin(a_ang)
    tx, ty = -math.sin(a_ang), math.cos(a_ang)
    nx, ny = math.cos(a_ang), math.sin(a_ang)
    head = 0.13
    tip = (ex + tx * head, ey + ty * head)
    base1 = (ex + nx * head * 0.95, ey + ny * head * 0.95)
    base2 = (ex - nx * head * 0.95, ey - ny * head * 0.95)
    on_head = in_triangle(x, y, tip, base1, base2)
    hw = stroke * 0.42
    on_hands = dist_to_segment(x, y, cx, cy, cx, cy - 0.17) <= hw or dist_to_segment(x, y, cx, cy, cx + 0.12, cy + 0.06) <= hw
    if on_ring or on_head or on_hands:
        return (*WHITE, 255)
    t = y
    col = tuple(round(TOP[i] * (1 - t) + BOTTOM[i] * t) for i in range(3))
    return (*col, 255)


def render(size):
    rows = []
    for py in range(size):
        row = bytearray([0])
        for px in range(size):
            acc = [0, 0, 0, 0]
            for sy in range(SS):
                for sx in range(SS):
                    x = (px + (sx + 0.5) / SS) / size
                    y = (py + (sy + 0.5) / SS) / size
                    c = shade(x, y, size)
                    if c:
                        acc[0] += c[0] * c[3]
                        acc[1] += c[1] * c[3]
                        acc[2] += c[2] * c[3]
                        acc[3] += c[3]
            n = SS * SS
            a = acc[3] / n
            if a:
                row += bytes((round(acc[0] / acc[3]), round(acc[1] / acc[3]), round(acc[2] / acc[3]), round(a)))
            else:
                row += b"\0\0\0\0"
        rows.append(bytes(row))
    raw = b"".join(rows)

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for size in (16, 32, 48, 128):
        with open(os.path.join(OUT, f"{size}.png"), "wb") as f:
            f.write(render(size))
    print("icons written to", os.path.abspath(OUT))
