#!/usr/bin/env python3
"""Center a qrencode XPM onto /dev/fb0, scaled to fit (~92% of short side).

Used on Legacy BIOS when fbi fails and Unicode terminal QR is unreadable.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile


def read_sys(path: str, default: str = "") -> str:
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return default


def parse_xpm(text: str) -> list[list[tuple[int, int, int]]]:
    strings = re.findall(r'"([^"]*)"', text)
    if not strings:
        raise ValueError("no XPM strings")

    idx = 0
    width = height = ncolors = cpp = 0
    while idx < len(strings):
        parts = strings[idx].split()
        if len(parts) >= 4 and parts[0].isdigit() and parts[1].isdigit():
            width, height, ncolors, cpp = (int(parts[0]), int(parts[1]), int(parts[2]), int(parts[3]))
            idx += 1
            break
        idx += 1
    else:
        raise ValueError("missing XPM header")

    colors: dict[str, tuple[int, int, int]] = {}
    for _ in range(ncolors):
        entry = strings[idx]
        idx += 1
        key = entry[:cpp]
        rest = entry[cpp:].strip()
        match = re.search(r"#([0-9A-Fa-f]{6})", rest)
        if match:
            hv = match.group(1)
            colors[key] = (int(hv[0:2], 16), int(hv[2:4], 16), int(hv[4:6], 16))
        elif "none" in rest.lower():
            colors[key] = (255, 255, 255)
        else:
            colors[key] = (0, 0, 0)

    rows: list[list[tuple[int, int, int]]] = []
    for _ in range(height):
        line = strings[idx]
        idx += 1
        row = []
        for x in range(width):
            ch = line[x * cpp : (x + 1) * cpp]
            row.append(colors.get(ch, (0, 0, 0)))
        rows.append(row)
    return rows


def scale_nearest(
    rows: list[list[tuple[int, int, int]]], scale: int
) -> list[list[tuple[int, int, int]]]:
    if scale <= 1:
        return rows
    out: list[list[tuple[int, int, int]]] = []
    for row in rows:
        wide = [px for px in row for _ in range(scale)]
        for _ in range(scale):
            out.append(wide)
    return out


def invert_rows(
    rows: list[list[tuple[int, int, int]]],
) -> list[list[tuple[int, int, int]]]:
    return [[(255 - r, 255 - g, 255 - b) for r, g, b in row] for row in rows]


def fb_geometry() -> tuple[int, int, int, int]:
    vs = read_sys("/sys/class/graphics/fb0/virtual_size", "1024,768")
    parts = [p for p in vs.replace("x", ",").split(",") if p]
    fb_w = int(parts[0])
    fb_h = int(parts[1])
    bpp = int(read_sys("/sys/class/graphics/fb0/bits_per_pixel", "32") or "32")
    stride = int(
        read_sys("/sys/class/graphics/fb0/line_length", str(fb_w * max(bpp // 8, 1)))
        or str(fb_w * max(bpp // 8, 1))
    )
    return fb_w, fb_h, bpp, stride


def make_bg_line(fb_w: int, bpp: int, stride: int, white: bool) -> bytes:
    if bpp == 32:
        pix = bytes((255, 255, 255, 0)) if white else bytes((0, 0, 0, 0))
        line = pix * fb_w
    elif bpp == 16:
        val = b"\xff\xff" if white else b"\x00\x00"
        line = val * fb_w
    else:
        line = (b"\xff" if white else b"\x00") * stride
    if len(line) < stride:
        line = line + (b"\x00" * (stride - len(line)))
    return line[:stride]


def pack_row(row: list[tuple[int, int, int]], bpp: int, max_px: int) -> bytes:
    if bpp == 32:
        buf = bytearray()
        for i, (r, g, b) in enumerate(row):
            if i >= max_px:
                break
            buf += bytes((b, g, r, 0))
        return bytes(buf)
    if bpp == 16:
        buf = bytearray()
        for i, (r, g, b) in enumerate(row):
            if i >= max_px:
                break
            val = ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)
            buf += val.to_bytes(2, "little")
        return bytes(buf)
    raise RuntimeError(f"unsupported bpp: {bpp}")


def blit(rows: list[list[tuple[int, int, int]]], inverted: bool, fill: float) -> None:
    if inverted:
        rows = invert_rows(rows)
    src_h = len(rows)
    src_w = len(rows[0]) if rows else 0
    if src_w <= 0 or src_h <= 0:
        raise ValueError("empty QR")

    fb_w, fb_h, bpp, stride = fb_geometry()
    if bpp not in (16, 32):
        raise RuntimeError(f"unsupported framebuffer depth: {bpp}")

    max_px = max(8, int(min(fb_w, fb_h) * fill))
    scale = max(1, max_px // max(src_w, src_h))
    while (src_w * scale > fb_w - 2) or (src_h * scale > fb_h - 2):
        scale -= 1
        if scale < 1:
            scale = 1
            break

    rows = scale_nearest(rows, scale)
    h = len(rows)
    w = len(rows[0])
    ox = max(0, (fb_w - w) // 2)
    oy = max(0, (fb_h - h) // 2)
    white_bg = not inverted
    bg_line = make_bg_line(fb_w, bpp, stride, white_bg)
    bytes_pp = bpp // 8

    with open("/dev/fb0", "r+b", buffering=0) as fb:
        for y in range(fb_h):
            fb.seek(y * stride)
            fb.write(bg_line)
        for y, row in enumerate(rows):
            if oy + y >= fb_h:
                break
            usable = min(len(row), fb_w - ox)
            if usable <= 0:
                continue
            fb.seek((oy + y) * stride + ox * bytes_pp)
            fb.write(pack_row(row[:usable], bpp, usable))


def qr_to_xpm(data: str, margin: int) -> str:
    with tempfile.NamedTemporaryFile(suffix=".xpm", delete=False) as tmp:
        path = tmp.name
    try:
        proc = subprocess.run(
            ["qrencode", "-t", "XPM", "-l", "L", "-m", str(margin), "-o", path, data],
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.strip() or "qrencode failed")
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("data", help="QR payload string")
    parser.add_argument("--inverted", action="store_true")
    parser.add_argument("--margin", type=int, default=2)
    parser.add_argument("--fill", type=float, default=0.92, help="fraction of short side")
    args = parser.parse_args()

    if not os.path.exists("/dev/fb0"):
        print("no /dev/fb0", file=sys.stderr)
        return 1

    try:
        xpm = qr_to_xpm(args.data, args.margin)
        rows = parse_xpm(xpm)
        blit(rows, args.inverted, args.fill)
    except Exception as exc:  # noqa: BLE001 - surface any blit error to shell
        print(f"qr_fb_blit: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
