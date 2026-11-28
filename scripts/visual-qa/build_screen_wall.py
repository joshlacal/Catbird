#!/usr/bin/env python3
"""Zero-SaaS PR "Screen Wall", Diff Strip, Interactive HTML Viewer & CI Report Builder.

Processes Catbird Visual QA candidate screenshots (`<surface>__<profile>.png`) and optional
`CatbirdDesignAuditReport` JSON receipts (`<surface>__<profile>.json`), compares against
optional baseline PNGs, and emits:

  1. screen-wall.png  — Full contact sheet grid (Rows = Surfaces × Cols = Trap Profiles)
  2. diff-strip.png   — Side-by-side `[Base | PR | Amplified Diff]` for changed/violating entries
  3. wall.html        — Self-contained interactive HTML viewer (before/after slider, filters, receipts)
  4. summary.md       — Self-updating GitHub PR comment Markdown summary table
  5. report.json      — Machine-readable CI report

Runs with ZERO third-party dependencies (pure Python 3 stdlib PNG codec + SSIM + bitmap font),
while optionally accelerating PNG I/O with Pillow (`PIL`) when installed.
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import html
import json
import math
import os
import pathlib
import struct
import subprocess
import sys
import tempfile
import unicodedata
import zlib
from dataclasses import dataclass, field
from typing import Any

try:
    from PIL import Image as _PILImage  # type: ignore
except Exception:  # pragma: no cover - optional acceleration
    _PILImage = None


# ---------------------------------------------------------------------------
# Canonical Ordering & Constants
# ---------------------------------------------------------------------------

CANONICAL_PROFILES: tuple[str, ...] = (
    "baseline-light",
    "dim-accent-trap",
    "oled-font-trap",
    "a11y-ax3-narrow",
    "glass-reduce-transparency",
    "resizability-wide-rtl",
)

CANONICAL_SURFACES: tuple[str, ...] = (
    "kit",
    "feed",
    "thread",
    "profile",
    "search",
    "chat",
    "composer",
    "settings",
    "onboarding",
    "ask-catbird",
    "notifications",
    "widgets",
)

CANONICAL_COUNT_KEYS: tuple[str, ...] = (
    "a11yAudit",
    "hitTarget",
    "nonAppFont",
    "accentLeak",
    "cornerRadius",
    "offGridSpacing",
    "reduceTransparency",
    "surfaceContrast",
)

CATEGORY_ALIASES: dict[str, str] = {
    "a11yaudit": "a11yAudit",
    "accessibilityaudit": "a11yAudit",
    "accessibility": "a11yAudit",
    "a11y": "a11yAudit",
    "hittarget": "hitTarget",
    "taptarget": "hitTarget",
    "hitregion": "hitTarget",
    "nonappfont": "nonAppFont",
    "fontbypass": "nonAppFont",
    "rawfont": "nonAppFont",
    "font": "nonAppFont",
    "accentleak": "accentLeak",
    "blueleak": "accentLeak",
    "hardcodedblue": "accentLeak",
    "accent": "accentLeak",
    "cornerradius": "cornerRadius",
    "rawradius": "cornerRadius",
    "radius": "cornerRadius",
    "offgridspacing": "offGridSpacing",
    "offgrid": "offGridSpacing",
    "spacing": "offGridSpacing",
    "reducetransparency": "reduceTransparency",
    "liquidglass": "reduceTransparency",
    "glass": "reduceTransparency",
    "surfacecontrast": "surfaceContrast",
    "contrast": "surfaceContrast",
}

PR_COMMENT_MARKER = "<!-- catbird-visual-qa-screen-wall -->"

# Palette (aligned with Catbird Dim canvas + Brand tokens)
COL_BG = (17, 19, 24, 255)          # #111318
COL_SURFACE = (29, 31, 38, 255)     # #1D1F26
COL_ELEVATED = (35, 37, 45, 255)    # #23252D
COL_BORDER = (58, 62, 74, 255)      # #3A3E4A
COL_TEXT = (230, 230, 236, 255)     # #E6E6EC
COL_MUTED = (168, 168, 176, 255)    # #A8A8B0
COL_PASS = (34, 197, 94, 255)       # #22C55E
COL_NEW = (81, 146, 255, 255)       # #5192FF (Catbird brand)
COL_WARN = (245, 158, 11, 255)      # #F59E0B
COL_FAIL = (239, 68, 68, 255)       # #EF4444
COL_DARK_TEXT = (11, 13, 18, 255)   # #0B0D12


# ---------------------------------------------------------------------------
# Pure-Stdlib 5x7 Bitmap Font (Zero External Font Dependencies)
# ---------------------------------------------------------------------------

FONT_5X7: dict[str, tuple[int, ...]] = {
    " ": (0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00),
    "!": (0x04, 0x04, 0x04, 0x04, 0x04, 0x00, 0x04),
    '"': (0x0A, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00),
    "#": (0x0A, 0x1F, 0x0A, 0x0A, 0x1F, 0x0A, 0x00),
    "%": (0x19, 0x1A, 0x04, 0x0B, 0x13, 0x00, 0x00),
    "&": (0x0C, 0x12, 0x14, 0x08, 0x15, 0x12, 0x0D),
    "'": (0x04, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00),
    "(": (0x02, 0x04, 0x08, 0x08, 0x08, 0x04, 0x02),
    ")": (0x08, 0x04, 0x02, 0x02, 0x02, 0x04, 0x08),
    "*": (0x00, 0x0A, 0x04, 0x1F, 0x04, 0x0A, 0x00),
    "+": (0x00, 0x04, 0x04, 0x1F, 0x04, 0x04, 0x00),
    ",": (0x00, 0x00, 0x00, 0x00, 0x04, 0x04, 0x08),
    "-": (0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00),
    ".": (0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C),
    "/": (0x01, 0x02, 0x02, 0x04, 0x08, 0x08, 0x10),
    "0": (0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E),
    "1": (0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E),
    "2": (0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F),
    "3": (0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E),
    "4": (0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02),
    "5": (0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E),
    "6": (0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E),
    "7": (0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08),
    "8": (0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E),
    "9": (0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C),
    ":": (0x00, 0x0C, 0x0C, 0x00, 0x0C, 0x0C, 0x00),
    ";": (0x00, 0x04, 0x04, 0x00, 0x04, 0x04, 0x08),
    "<": (0x02, 0x04, 0x08, 0x10, 0x08, 0x04, 0x02),
    "=": (0x00, 0x00, 0x1F, 0x00, 0x1F, 0x00, 0x00),
    ">": (0x08, 0x04, 0x02, 0x01, 0x02, 0x04, 0x08),
    "?": (0x0E, 0x11, 0x01, 0x02, 0x04, 0x00, 0x04),
    "@": (0x0E, 0x11, 0x17, 0x15, 0x17, 0x10, 0x0E),
    "A": (0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11),
    "B": (0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E),
    "C": (0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E),
    "D": (0x1C, 0x12, 0x11, 0x11, 0x11, 0x12, 0x1C),
    "E": (0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F),
    "F": (0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10),
    "G": (0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F),
    "H": (0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11),
    "I": (0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E),
    "J": (0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C),
    "K": (0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11),
    "L": (0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F),
    "M": (0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11),
    "N": (0x11, 0x11, 0x19, 0x15, 0x13, 0x11, 0x11),
    "O": (0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E),
    "P": (0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10),
    "Q": (0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D),
    "R": (0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11),
    "S": (0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E),
    "T": (0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04),
    "U": (0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E),
    "V": (0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04),
    "W": (0x11, 0x11, 0x11, 0x15, 0x15, 0x1B, 0x11),
    "X": (0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11),
    "Y": (0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04),
    "Z": (0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F),
    "[": (0x0E, 0x08, 0x08, 0x08, 0x08, 0x08, 0x0E),
    "]": (0x0E, 0x02, 0x02, 0x02, 0x02, 0x02, 0x0E),
    "_": (0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1F),
    "|": (0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04),
    "~": (0x00, 0x00, 0x08, 0x15, 0x02, 0x00, 0x00),
    "✓": (0x00, 0x01, 0x02, 0x04, 0x14, 0x08, 0x00),
    "Δ": (0x04, 0x04, 0x0A, 0x0A, 0x11, 0x11, 0x1F),
    "·": (0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00),
    "—": (0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00),
    "–": (0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00),
}

UNICODE_BITMAP_REPLACEMENTS: dict[str, str] = {
    "\u2014": "-",    # em-dash —
    "\u2013": "-",    # en-dash –
    "\u2012": "-",    # figure dash ‒
    "\u2015": "-",    # horizontal bar ―
    "\u2010": "-",    # hyphen ‐
    "\u2011": "-",    # non-breaking hyphen ‑
    "\u2212": "-",    # minus sign −
    "\u00d7": "X",    # multiplication sign ×
    "\u00f7": "/",    # division sign ÷
    "\u201c": '"',    # left double quote “
    "\u201d": '"',    # right double quote ”
    "\u2018": "'",    # left single quote ‘
    "\u2019": "'",    # right single quote ’
    "\u2032": "'",    # prime ′
    "\u2033": '"',    # double prime ″
    "\u2026": "...",  # ellipsis …
    "\u2022": "·",    # bullet •
    "\u2219": "·",    # bullet operator ∙
    "\u00a0": " ",    # non-breaking space
    "\u2009": " ",    # thin space
    "\u202f": " ",    # narrow no-break space
    "\u2192": "->",   # right arrow →
    "\u2190": "<-",   # left arrow ←
    "\u2194": "<->",  # left-right arrow ↔
    "\u2265": ">=",   # greater-than or equal ≥
    "\u2264": "<=",   # less-than or equal ≤
    "\u2260": "!=",   # not equal ≠
    "\u2248": "~",    # almost equal ≈
    "\u00b1": "+/-",  # plus-minus ±
    "\u2714": "✓",    # heavy check mark ✔
    "\u2715": "X",    # multiplication x ✕
    "\u2716": "X",    # heavy multiplication x ✖
    "\u2717": "X",    # ballot x ✗
}


def sanitize_bitmap_text(text: str) -> str:
    """Normalize text for the 5x7 bitmap font so Unicode punctuation never renders as '?'."""
    out: list[str] = []
    for ch in text:
        if ch in UNICODE_BITMAP_REPLACEMENTS:
            out.append(UNICODE_BITMAP_REPLACEMENTS[ch])
            continue
        upper = ch.upper()
        if upper in FONT_5X7:
            out.append(upper)
            continue
        # Fold accented Latin letters (e.g. é -> E) via NFKD decomposition
        decomposed = "".join(
            c for c in unicodedata.normalize("NFKD", upper) if not unicodedata.combining(c)
        )
        if decomposed and all(c in FONT_5X7 for c in decomposed):
            out.append(decomposed)
        elif unicodedata.category(ch).startswith("Pd"):  # Any other Unicode dash punctuation
            out.append("-")
        elif unicodedata.category(ch).startswith("Z"):   # Any other Unicode space separator
            out.append(" ")
        else:
            out.append("?")
    return "".join(out)


# ---------------------------------------------------------------------------
# Pure-Stdlib RGBA Image & PNG Codec
# ---------------------------------------------------------------------------

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def _paeth_predictor(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


class ImageRGBA:
    """Lightweight RGBA8 raster buffer with pure-stdlib PNG I/O and drawing primitives."""

    __slots__ = ("width", "height", "pixels")

    def __init__(self, width: int, height: int, pixels: bytearray | None = None, fill: tuple[int, int, int, int] = COL_BG) -> None:
        self.width = max(1, int(width))
        self.height = max(1, int(height))
        if pixels is not None:
            expected = self.width * self.height * 4
            if len(pixels) != expected:
                raise ValueError(f"Expected {expected} RGBA bytes, got {len(pixels)}")
            self.pixels = pixels
        else:
            row = bytes(fill) * self.width
            self.pixels = bytearray(row * self.height)

    @classmethod
    def from_png(cls, path: pathlib.Path, backend: str = "auto") -> "ImageRGBA":
        if backend == "pil" or (backend == "auto" and _PILImage is not None):
            if _PILImage is not None:
                with _PILImage.open(path) as im:
                    rgba = im.convert("RGBA")
                    return cls(rgba.width, rgba.height, bytearray(rgba.tobytes()))
        return cls._decode_png_bytes(path.read_bytes(), source_path=path)

    @classmethod
    def _decode_png_bytes(cls, data: bytes, source_path: pathlib.Path | None = None) -> "ImageRGBA":
        if not data.startswith(PNG_SIGNATURE):
            raise ValueError(f"Invalid PNG signature: {source_path or '<bytes>'}")
        pos = 8
        width = height = bit_depth = color_type = interlace = 0
        idat_chunks: list[bytes] = []
        palette: list[tuple[int, int, int]] = []
        trns: bytes = b""

        while pos + 8 <= len(data):
            length, chunk_type = struct.unpack(">I4s", data[pos:pos + 8])
            pos += 8
            chunk = data[pos:pos + length]
            pos += length + 4  # skip CRC
            if chunk_type == b"IHDR":
                width, height, bit_depth, color_type, compression, filter_method, interlace = struct.unpack(">IIBBBBB", chunk)
                if compression != 0 or filter_method != 0:
                    raise ValueError(f"Unsupported PNG compression/filter: {compression}/{filter_method}")
            elif chunk_type == b"PLTE":
                palette = [
                    (chunk[i], chunk[i + 1], chunk[i + 2])
                    for i in range(0, len(chunk) - (len(chunk) % 3), 3)
                ]
            elif chunk_type == b"tRNS":
                trns = chunk
            elif chunk_type == b"IDAT":
                idat_chunks.append(chunk)
            elif chunk_type == b"IEND":
                break

        if width <= 0 or height <= 0:
            raise ValueError(f"PNG missing valid IHDR: {source_path or '<bytes>'}")

        if interlace != 0:
            # Fallback to macOS sips or Pillow for Adam7 interlaced PNGs
            if _PILImage is not None and source_path is not None:
                with _PILImage.open(source_path) as im:
                    rgba = im.convert("RGBA")
                    return cls(rgba.width, rgba.height, bytearray(rgba.tobytes()))
            if source_path is not None and sys.platform == "darwin":
                with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tf:
                    tmp_path = pathlib.Path(tf.name)
                try:
                    subprocess.run(
                        ["sips", "-s", "format", "png", str(source_path), "--out", str(tmp_path)],
                        check=True,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                    )
                    return cls._decode_png_bytes(tmp_path.read_bytes(), source_path=None)
                finally:
                    tmp_path.unlink(missing_ok=True)
            raise ValueError("Interlaced PNG requires Pillow or macOS sips")

        channels_map = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}
        if color_type not in channels_map:
            raise ValueError(f"Unsupported PNG color type: {color_type}")
        channels = channels_map[color_type]
        bits_per_pixel = channels * bit_depth
        stride = (width * bits_per_pixel + 7) // 8
        bpp = max(1, bits_per_pixel // 8)

        raw = zlib.decompress(b"".join(idat_chunks))
        expected_raw = height * (stride + 1)
        if len(raw) < expected_raw:
            raise ValueError(f"Truncated PNG IDAT: expected {expected_raw}, got {len(raw)}")

        # Unfilter scanlines
        prev = bytearray(stride)
        unfiltered = bytearray(height * stride)
        raw_mv = memoryview(raw)
        offset = 0
        for y in range(height):
            ftype = raw_mv[offset]
            offset += 1
            cur = bytearray(raw_mv[offset:offset + stride])
            offset += stride

            if ftype == 0:
                pass
            elif ftype == 1:  # Sub
                for i in range(bpp, stride):
                    cur[i] = (cur[i] + cur[i - bpp]) & 0xFF
            elif ftype == 2:  # Up
                for i in range(stride):
                    cur[i] = (cur[i] + prev[i]) & 0xFF
            elif ftype == 3:  # Average
                for i in range(bpp):
                    cur[i] = (cur[i] + (prev[i] >> 1)) & 0xFF
                for i in range(bpp, stride):
                    cur[i] = (cur[i] + ((cur[i - bpp] + prev[i]) >> 1)) & 0xFF
            elif ftype == 4:  # Paeth
                for i in range(bpp):
                    cur[i] = (cur[i] + prev[i]) & 0xFF
                for i in range(bpp, stride):
                    cur[i] = (cur[i] + _paeth_predictor(cur[i - bpp], prev[i], prev[i - bpp])) & 0xFF
            else:
                raise ValueError(f"Unknown PNG filter type: {ftype}")

            unfiltered[y * stride:(y + 1) * stride] = cur
            prev = cur

        # Fast path: 8-bit RGBA
        if color_type == 6 and bit_depth == 8:
            return cls(width, height, unfiltered)

        out = bytearray(width * height * 4)

        # Fast path: 8-bit RGB
        if color_type == 2 and bit_depth == 8 and not trns:
            out[0::4] = unfiltered[0::3]
            out[1::4] = unfiltered[1::3]
            out[2::4] = unfiltered[2::3]
            out[3::4] = b"\xff" * (width * height)
            return cls(width, height, out)

        # General conversion to RGBA8
        trns_gray = struct.unpack(">H", trns[:2])[0] if color_type == 0 and len(trns) >= 2 else None
        trns_rgb = struct.unpack(">HHH", trns[:6]) if color_type == 2 and len(trns) >= 6 else None

        dst = 0
        for y in range(height):
            row_start = y * stride
            if color_type == 6 and bit_depth == 16:
                for x in range(width):
                    i = row_start + x * 8
                    out[dst] = unfiltered[i]
                    out[dst + 1] = unfiltered[i + 2]
                    out[dst + 2] = unfiltered[i + 4]
                    out[dst + 3] = unfiltered[i + 6]
                    dst += 4
            elif color_type == 2 and bit_depth == 8:
                for x in range(width):
                    i = row_start + x * 3
                    r, g, b = unfiltered[i], unfiltered[i + 1], unfiltered[i + 2]
                    a = 0 if trns_rgb == (r, g, b) else 255
                    out[dst] = r
                    out[dst + 1] = g
                    out[dst + 2] = b
                    out[dst + 3] = a
                    dst += 4
            elif color_type == 2 and bit_depth == 16:
                for x in range(width):
                    i = row_start + x * 6
                    r16 = (unfiltered[i] << 8) | unfiltered[i + 1]
                    g16 = (unfiltered[i + 2] << 8) | unfiltered[i + 3]
                    b16 = (unfiltered[i + 4] << 8) | unfiltered[i + 5]
                    a = 0 if trns_rgb == (r16, g16, b16) else 255
                    out[dst] = unfiltered[i]
                    out[dst + 1] = unfiltered[i + 2]
                    out[dst + 2] = unfiltered[i + 4]
                    out[dst + 3] = a
                    dst += 4
            elif color_type == 0 and bit_depth in (8, 16):
                step = 1 if bit_depth == 8 else 2
                for x in range(width):
                    i = row_start + x * step
                    val16 = unfiltered[i] if bit_depth == 8 else ((unfiltered[i] << 8) | unfiltered[i + 1])
                    v = unfiltered[i]
                    a = 0 if trns_gray == val16 else 255
                    out[dst] = v
                    out[dst + 1] = v
                    out[dst + 2] = v
                    out[dst + 3] = a
                    dst += 4
            elif color_type == 4 and bit_depth in (8, 16):
                step = 2 if bit_depth == 8 else 4
                a_off = 1 if bit_depth == 8 else 2
                for x in range(width):
                    i = row_start + x * step
                    v = unfiltered[i]
                    out[dst] = v
                    out[dst + 1] = v
                    out[dst + 2] = v
                    out[dst + 3] = unfiltered[i + a_off]
                    dst += 4
            elif color_type == 3:
                mask = (1 << bit_depth) - 1
                per_byte = 8 // bit_depth
                for x in range(width):
                    byte_val = unfiltered[row_start + (x // per_byte)]
                    shift = 8 - bit_depth * ((x % per_byte) + 1)
                    idx = (byte_val >> shift) & mask
                    r, g, b = palette[idx] if idx < len(palette) else (0, 0, 0)
                    a = trns[idx] if idx < len(trns) else 255
                    out[dst] = r
                    out[dst + 1] = g
                    out[dst + 2] = b
                    out[dst + 3] = a
                    dst += 4
            else:
                raise ValueError(f"Unsupported PNG color_type={color_type} bit_depth={bit_depth}")

        return cls(width, height, out)

    def to_png_bytes(self, rgb_only: bool = False, backend: str = "auto") -> bytes:
        if backend == "pil" or (backend == "auto" and _PILImage is not None):
            if _PILImage is not None:
                import io
                im = _PILImage.frombytes("RGBA", (self.width, self.height), bytes(self.pixels))
                if rgb_only:
                    im = im.convert("RGB")
                buf = io.BytesIO()
                im.save(buf, format="PNG", compress_level=5)
                return buf.getvalue()

        def chunk(ctype: bytes, payload: bytes) -> bytes:
            return struct.pack(">I", len(payload)) + ctype + payload + struct.pack(">I", zlib.crc32(ctype + payload) & 0xFFFFFFFF)

        if rgb_only:
            rgb = bytearray(self.width * self.height * 3)
            rgb[0::3] = self.pixels[0::4]
            rgb[1::3] = self.pixels[1::4]
            rgb[2::3] = self.pixels[2::4]
            row_bytes = self.width * 3
            raw = bytearray(self.height * (row_bytes + 1))
            src_mv = memoryview(rgb)
            for y in range(self.height):
                dst_off = y * (row_bytes + 1)
                raw[dst_off] = 0
                raw[dst_off + 1:dst_off + 1 + row_bytes] = src_mv[y * row_bytes:(y + 1) * row_bytes]
            color_type = 2
        else:
            row_bytes = self.width * 4
            raw = bytearray(self.height * (row_bytes + 1))
            src_mv = memoryview(self.pixels)
            for y in range(self.height):
                dst_off = y * (row_bytes + 1)
                raw[dst_off] = 0
                raw[dst_off + 1:dst_off + 1 + row_bytes] = src_mv[y * row_bytes:(y + 1) * row_bytes]
            color_type = 6

        ihdr = struct.pack(">IIBBBBB", self.width, self.height, 8, color_type, 0, 0, 0)
        idat = zlib.compress(bytes(raw), level=5)
        return PNG_SIGNATURE + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")

    def save_png(self, path: pathlib.Path, rgb_only: bool = False, backend: str = "auto") -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(self.to_png_bytes(rgb_only=rgb_only, backend=backend))

    # --- Drawing primitives ---

    def fill_rect(self, x: int, y: int, w: int, h: int, color: tuple[int, int, int, int]) -> None:
        x0 = max(0, x)
        y0 = max(0, y)
        x1 = min(self.width, x + w)
        y1 = min(self.height, y + h)
        if x0 >= x1 or y0 >= y1:
            return
        span_w = x1 - x0
        row_data = bytes(color) * span_w
        stride = self.width * 4
        for row in range(y0, y1):
            start = row * stride + x0 * 4
            self.pixels[start:start + span_w * 4] = row_data

    def stroke_rect(self, x: int, y: int, w: int, h: int, color: tuple[int, int, int, int], thickness: int = 2) -> None:
        t = max(1, thickness)
        self.fill_rect(x, y, w, t, color)
        self.fill_rect(x, y + h - t, w, t, color)
        self.fill_rect(x, y, t, h, color)
        self.fill_rect(x + w - t, y, t, h, color)

    def fill_rounded_rect(self, x: int, y: int, w: int, h: int, radius: int, color: tuple[int, int, int, int]) -> None:
        r = max(0, min(radius, w // 2, h // 2))
        if r == 0:
            self.fill_rect(x, y, w, h, color)
            return
        self.fill_rect(x + r, y, w - 2 * r, h, color)
        self.fill_rect(x, y + r, r, h - 2 * r, color)
        self.fill_rect(x + w - r, y + r, r, h - 2 * r, color)
        r_sq = r * r
        for dy in range(r):
            dx_limit = int(math.floor(math.sqrt(max(0, r_sq - (r - dy - 0.5) ** 2))))
            inset = r - dx_limit
            self.fill_rect(x + inset, y + dy, w - 2 * inset, 1, color)
            self.fill_rect(x + inset, y + h - 1 - dy, w - 2 * inset, 1, color)

    def blit(self, src: "ImageRGBA", dx: int, dy: int) -> None:
        sx0 = max(0, -dx)
        sy0 = max(0, -dy)
        dx0 = max(0, dx)
        dy0 = max(0, dy)
        copy_w = min(src.width - sx0, self.width - dx0)
        copy_h = min(src.height - sy0, self.height - dy0)
        if copy_w <= 0 or copy_h <= 0:
            return
        dst_stride = self.width * 4
        src_stride = src.width * 4
        span = copy_w * 4
        src_mv = memoryview(src.pixels)
        for row in range(copy_h):
            s_off = (sy0 + row) * src_stride + sx0 * 4
            d_off = (dy0 + row) * dst_stride + dx0 * 4
            self.pixels[d_off:d_off + span] = src_mv[s_off:s_off + span]

    def draw_text(
        self,
        x: int,
        y: int,
        text: str,
        color: tuple[int, int, int, int] = COL_TEXT,
        scale: int = 1,
        max_width: int | None = None,
    ) -> int:
        s = max(1, scale)
        char_adv = 6 * s
        rendered = sanitize_bitmap_text(text)
        if max_width is not None and len(rendered) * char_adv > max_width:
            max_chars = max(1, (max_width // char_adv) - 1)
            rendered = rendered[:max_chars] + "."
        cx = x
        for ch in rendered:
            glyph = FONT_5X7.get(ch, FONT_5X7["?"])
            for row_idx, bits in enumerate(glyph):
                if bits == 0:
                    continue
                for col_idx in range(5):
                    if bits & (1 << (4 - col_idx)):
                        self.fill_rect(cx + col_idx * s, y + row_idx * s, s, s, color)
            cx += char_adv
        return cx - x

    def draw_pill(
        self,
        x: int,
        y: int,
        text: str,
        bg: tuple[int, int, int, int],
        fg: tuple[int, int, int, int] = COL_DARK_TEXT,
        scale: int = 1,
        pad_x: int = 7,
        pad_y: int = 4,
    ) -> int:
        s = max(1, scale)
        rendered = sanitize_bitmap_text(text)
        tw = max(1, len(rendered) * 6 * s - s)
        th = 7 * s
        pw = tw + pad_x * 2
        ph = th + pad_y * 2
        self.fill_rounded_rect(x, y, pw, ph, ph // 2, bg)
        self.draw_text(x + pad_x, y + pad_y, rendered, color=fg, scale=s)
        return pw

    def resize_fit(self, max_w: int, max_h: int) -> "ImageRGBA":
        if self.width <= max_w and self.height <= max_h:
            return self
        ratio = min(max_w / self.width, max_h / self.height)
        tw = max(1, int(round(self.width * ratio)))
        th = max(1, int(round(self.height * ratio)))
        return self.resize(tw, th)

    def resize(self, target_w: int, target_h: int) -> "ImageRGBA":
        tw = max(1, target_w)
        th = max(1, target_h)
        if tw == self.width and th == self.height:
            return self
        if _PILImage is not None:
            im = _PILImage.frombytes("RGBA", (self.width, self.height), bytes(self.pixels))
            resized = im.resize((tw, th), _PILImage.Resampling.LANCZOS)
            return ImageRGBA(tw, th, bytearray(resized.tobytes()))

        # Fast precomputed nearest/area-stride resample in pure Python
        out = bytearray(tw * th * 4)
        src = self.pixels
        sw, sh = self.width, self.height
        x_map = [min(sw - 1, (x * sw) // tw) * 4 for x in range(tw)]
        src_stride = sw * 4
        dst_off = 0
        for y in range(th):
            sy_off = min(sh - 1, (y * sh) // th) * src_stride
            for sx_off in x_map:
                idx = sy_off + sx_off
                out[dst_off] = src[idx]
                out[dst_off + 1] = src[idx + 1]
                out[dst_off + 2] = src[idx + 2]
                out[dst_off + 3] = src[idx + 3]
                dst_off += 4
        return ImageRGBA(tw, th, out)


# ---------------------------------------------------------------------------
# Per-Image Diffing, Heatmap & SSIM
# ---------------------------------------------------------------------------

@dataclass
class DiffResult:
    has_baseline: bool
    size_mismatch: bool
    base_size: tuple[int, int] | None
    cand_size: tuple[int, int]
    changed_pixels: int
    total_pixels: int
    delta_ratio: float | None
    mean_abs_diff: float | None
    max_channel_diff: int
    ssim: float | None
    heatmap: ImageRGBA


def _downsample_luma(img: ImageRGBA, max_dim: int = 320) -> tuple[int, int, list[float]]:
    w, h = img.width, img.height
    step = max(1, int(math.ceil(max(w, h) / max_dim)))
    sw = max(1, (w + step - 1) // step)
    sh = max(1, (h + step - 1) // step)
    px = img.pixels
    stride = w * 4
    luma: list[float] = [0.0] * (sw * sh)
    dst = 0
    for y in range(0, h, step):
        row = y * stride
        for x in range(0, w, step):
            i = row + x * 4
            luma[dst] = 0.299 * px[i] + 0.587 * px[i + 1] + 0.114 * px[i + 2]
            dst += 1
    return sw, sh, luma


def compute_ssim(img_a: ImageRGBA, img_b: ImageRGBA) -> float:
    """Compute mean windowed Structural Similarity (SSIM) over luminance [0..255]."""
    if img_a.width == img_b.width and img_a.height == img_b.height and img_a.pixels == img_b.pixels:
        return 1.0

    # Align on overlapping dimensions (or padded union if mismatched)
    w = max(img_a.width, img_b.width)
    h = max(img_a.height, img_b.height)
    if img_a.width != w or img_a.height != h:
        pa = ImageRGBA(w, h, fill=(0, 0, 0, 255))
        pa.blit(img_a, 0, 0)
        img_a = pa
    if img_b.width != w or img_b.height != h:
        pb = ImageRGBA(w, h, fill=(0, 0, 0, 255))
        pb.blit(img_b, 0, 0)
        img_b = pb

    sw, sh, la = _downsample_luma(img_a, max_dim=280)
    _, _, lb = _downsample_luma(img_b, max_dim=280)

    c1 = 6.5025    # (0.01 * 255)^2
    c2 = 58.5225   # (0.03 * 255)^2
    win = 8 if min(sw, sh) >= 8 else max(1, min(sw, sh))

    ssim_sum = 0.0
    blocks = 0
    for by in range(0, sh, win):
        y_end = min(sh, by + win)
        for bx in range(0, sw, win):
            x_end = min(sw, bx + win)
            n = (y_end - by) * (x_end - bx)
            if n == 0:
                continue
            sa = sb = sa2 = sb2 = sab = 0.0
            for y in range(by, y_end):
                row_off = y * sw
                for x in range(bx, x_end):
                    va = la[row_off + x]
                    vb = lb[row_off + x]
                    sa += va
                    sb += vb
                    sa2 += va * va
                    sb2 += vb * vb
                    sab += va * vb
            inv_n = 1.0 / n
            ma = sa * inv_n
            mb = sb * inv_n
            va_var = max(0.0, sa2 * inv_n - ma * ma)
            vb_var = max(0.0, sb2 * inv_n - mb * mb)
            cov = sab * inv_n - ma * mb
            num = (2.0 * ma * mb + c1) * (2.0 * cov + c2)
            den = (ma * ma + mb * mb + c1) * (va_var + vb_var + c2)
            ssim_sum += (num / den) if den != 0.0 else 1.0
            blocks += 1

    if blocks == 0:
        return 1.0
    return max(-1.0, min(1.0, ssim_sum / blocks))


def _heat_color(diff_val: int) -> tuple[int, int, int]:
    """Map amplified channel diff [1..255] onto a high-visibility yellow→orange→magenta ramp."""
    t = min(1.0, diff_val / 48.0)
    if t < 0.5:
        u = t * 2.0
        # Yellow (255, 224, 64) -> Orange-Red (255, 96, 32)
        r = 255
        g = int(224 - 128 * u)
        b = int(64 - 32 * u)
    else:
        u = (t - 0.5) * 2.0
        # Orange-Red (255, 96, 32) -> Hot Magenta (255, 24, 148)
        r = 255
        g = int(96 - 72 * u)
        b = int(32 + 116 * u)
    return r, g, b


def compare_images(
    baseline: ImageRGBA | None,
    candidate: ImageRGBA,
    channel_tolerance: int = 2,
) -> DiffResult:
    """Compare candidate vs optional baseline and build an amplified diff heatmap."""
    cw, ch = candidate.width, candidate.height
    if baseline is None:
        placeholder = ImageRGBA(cw, ch, fill=COL_ELEVATED)
        placeholder.stroke_rect(2, 2, max(1, cw - 4), max(1, ch - 4), COL_NEW, thickness=2)
        placeholder.draw_text(12, max(8, ch // 2 - 8), "NO BASELINE", color=COL_NEW, scale=max(1, min(3, cw // 100)))
        return DiffResult(
            has_baseline=False,
            size_mismatch=False,
            base_size=None,
            cand_size=(cw, ch),
            changed_pixels=0,
            total_pixels=cw * ch,
            delta_ratio=None,
            mean_abs_diff=None,
            max_channel_diff=0,
            ssim=None,
            heatmap=placeholder,
        )

    bw, bh = baseline.width, baseline.height
    size_mismatch = (bw != cw) or (bh != ch)

    # Identical fast path (C-speed bytes equality)
    if not size_mismatch and baseline.pixels == candidate.pixels:
        dimmed = bytearray(cw * ch * 4)
        cp = candidate.pixels
        for i in range(0, len(cp), 4):
            g = (cp[i] * 77 + cp[i + 1] * 150 + cp[i + 2] * 29) >> 10  # ~0.25 * luma
            dimmed[i] = g
            dimmed[i + 1] = g
            dimmed[i + 2] = g
            dimmed[i + 3] = 255
        return DiffResult(
            has_baseline=True,
            size_mismatch=False,
            base_size=(bw, bh),
            cand_size=(cw, ch),
            changed_pixels=0,
            total_pixels=cw * ch,
            delta_ratio=0.0,
            mean_abs_diff=0.0,
            max_channel_diff=0,
            ssim=1.0,
            heatmap=ImageRGBA(cw, ch, dimmed),
        )

    uw = max(bw, cw)
    uh = max(bh, ch)
    total = uw * uh
    heat = bytearray(total * 4)
    bp = baseline.pixels
    cp = candidate.pixels
    b_stride = bw * 4
    c_stride = cw * 4
    changed = 0
    abs_sum = 0
    max_diff = 0
    tol = max(0, channel_tolerance)

    if not size_mismatch:
        for i in range(0, total * 4, 4):
            dr = abs(cp[i] - bp[i])
            dg = abs(cp[i + 1] - bp[i + 1])
            db = abs(cp[i + 2] - bp[i + 2])
            da = abs(cp[i + 3] - bp[i + 3])
            md = max(dr, dg, db, da)
            abs_sum += dr + dg + db
            if md > max_diff:
                max_diff = md
            if md > tol:
                changed += 1
                hr, hg, hb = _heat_color(md)
                heat[i] = hr
                heat[i + 1] = hg
                heat[i + 2] = hb
                heat[i + 3] = 255
            else:
                g = (cp[i] * 77 + cp[i + 1] * 150 + cp[i + 2] * 29) >> 10
                heat[i] = g
                heat[i + 1] = g
                heat[i + 2] = g
                heat[i + 3] = 255
    else:
        dst = 0
        for y in range(uh):
            in_by = y < bh
            in_cy = y < ch
            by_off = y * b_stride
            cy_off = y * c_stride
            for x in range(uw):
                in_b = in_by and x < bw
                in_c = in_cy and x < cw
                if in_b and in_c:
                    bi = by_off + x * 4
                    ci = cy_off + x * 4
                    dr = abs(cp[ci] - bp[bi])
                    dg = abs(cp[ci + 1] - bp[bi + 1])
                    db = abs(cp[ci + 2] - bp[bi + 2])
                    da = abs(cp[ci + 3] - bp[bi + 3])
                    md = max(dr, dg, db, da)
                    abs_sum += dr + dg + db
                    if md > max_diff:
                        max_diff = md
                    if md > tol:
                        changed += 1
                        hr, hg, hb = _heat_color(md)
                        heat[dst] = hr
                        heat[dst + 1] = hg
                        heat[dst + 2] = hb
                        heat[dst + 3] = 255
                    else:
                        g = (cp[ci] * 77 + cp[ci + 1] * 150 + cp[ci + 2] * 29) >> 10
                        heat[dst] = g
                        heat[dst + 1] = g
                        heat[dst + 2] = g
                        heat[dst + 3] = 255
                else:
                    changed += 1
                    abs_sum += 765
                    max_diff = 255
                    heat[dst] = 239
                    heat[dst + 1] = 68
                    heat[dst + 2] = 68
                    heat[dst + 3] = 255
                dst += 4

    ssim_val = compute_ssim(baseline, candidate)
    return DiffResult(
        has_baseline=True,
        size_mismatch=size_mismatch,
        base_size=(bw, bh),
        cand_size=(cw, ch),
        changed_pixels=changed,
        total_pixels=total,
        delta_ratio=changed / total if total else 0.0,
        mean_abs_diff=(abs_sum / (total * 3.0 * 255.0)) if total else 0.0,
        max_channel_diff=max_diff,
        ssim=ssim_val,
        heatmap=ImageRGBA(uw, uh, heat),
    )


# ---------------------------------------------------------------------------
# CatbirdDesignAuditReport Parsing
# ---------------------------------------------------------------------------

def _normalize_category(raw: str) -> str:
    cleaned = "".join(ch for ch in raw.lower() if ch.isalnum())
    return CATEGORY_ALIASES.get(cleaned, raw)


@dataclass
class ParsedAuditReceipt:
    present: bool = False
    raw: dict[str, Any] = field(default_factory=dict)
    counts: dict[str, int] = field(default_factory=lambda: {k: 0 for k in CANONICAL_COUNT_KEYS})
    total_violations: int = 0
    error_count: int = 0
    warning_count: int = 0
    violations: list[dict[str, Any]] = field(default_factory=list)
    a11y_audit_issues: list[dict[str, Any]] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)
    metrics: dict[str, Any] = field(default_factory=dict)


def parse_audit_receipt(path: pathlib.Path | None) -> ParsedAuditReceipt:
    result = ParsedAuditReceipt()
    if path is None or not path.is_file():
        return result

    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        return result

    result.present = True
    result.raw = data
    result.metadata = {
        key: data[key]
        for key in (
            "schemaVersion",
            "surface",
            "profile",
            "viewport",
            "theme",
            "accent",
            "fontStyle",
            "dynamicType",
            "reduceTransparency",
            "reduceMotion",
            "highContrast",
            "timestamp",
        )
        if key in data
    }
    if isinstance(data.get("metrics"), dict):
        result.metrics = dict(data["metrics"])

    raw_violations = data.get("violations")
    if isinstance(raw_violations, list):
        for item in raw_violations:
            if not isinstance(item, dict):
                continue
            norm_cat = _normalize_category(str(item.get("category", "other")))
            sev = str(item.get("severity", "error")).lower()
            normalized_item = dict(item)
            normalized_item["category"] = norm_cat
            normalized_item["severity"] = sev
            result.violations.append(normalized_item)
            if sev in ("warning", "warn"):
                result.warning_count += 1
            else:
                result.error_count += 1

    raw_a11y = data.get("a11yAuditIssues") or data.get("accessibilityAuditIssues")
    if isinstance(raw_a11y, list):
        for item in raw_a11y:
            if isinstance(item, dict):
                result.a11y_audit_issues.append(dict(item))
            else:
                result.a11y_audit_issues.append({"description": str(item)})

    # Build category counts: prefer explicit counts, fall back to derived counts
    derived: dict[str, int] = {k: 0 for k in CANONICAL_COUNT_KEYS}
    extra_count = 0
    for v in result.violations:
        cat = v["category"]
        if cat in derived:
            derived[cat] += 1
        else:
            extra_count += 1

    a11y_from_field = int(data.get("a11yAuditCount", 0) or 0)
    derived["a11yAudit"] = max(derived["a11yAudit"], len(result.a11y_audit_issues), a11y_from_field)

    explicit_counts = data.get("counts")
    counts: dict[str, int] = {k: 0 for k in CANONICAL_COUNT_KEYS}
    if isinstance(explicit_counts, dict):
        for raw_k, raw_v in explicit_counts.items():
            if str(raw_k).lower() == "total":
                continue
            norm_k = _normalize_category(str(raw_k))
            if norm_k in counts:
                counts[norm_k] = max(counts[norm_k], int(raw_v or 0))
            else:
                extra_count = max(extra_count, int(raw_v or 0))
        for k in CANONICAL_COUNT_KEYS:
            counts[k] = max(counts[k], derived[k])
        explicit_total = int(explicit_counts.get("total", 0) or 0)
        computed_total = sum(counts.values()) + extra_count
        result.total_violations = max(explicit_total, computed_total)
    else:
        counts = derived
        result.total_violations = sum(counts.values()) + extra_count

    # Ensure error_count reflects a11y audit issues if they were outside violations[]
    if result.total_violations > (result.error_count + result.warning_count):
        result.error_count += result.total_violations - (result.error_count + result.warning_count)

    result.counts = counts
    return result


# ---------------------------------------------------------------------------
# Entry Discovery & Evaluation
# ---------------------------------------------------------------------------

@dataclass
class ScreenEntry:
    surface: str
    profile: str
    stem: str
    candidate_path: pathlib.Path
    baseline_path: pathlib.Path | None
    receipt_path: pathlib.Path | None
    candidate_img: ImageRGBA
    baseline_img: ImageRGBA | None
    diff: DiffResult
    receipt: ParsedAuditReceipt
    status: str  # "violations" | "changed" | "new" | "clean"
    diff_panel_path: pathlib.Path | None = None

    @property
    def exceeds_delta(self) -> bool:
        return self.diff.size_mismatch or (
            self.diff.delta_ratio is not None and self.status in ("changed", "violations")
        )


def parse_surface_profile(stem: str) -> tuple[str, str]:
    if "__" in stem:
        surface, profile = stem.split("__", 1)
        return surface, profile
    return stem, "baseline-light"


def ordered_names(names: set[str], canonical: tuple[str, ...]) -> list[str]:
    result = [n for n in canonical if n in names]
    extras = sorted(names - set(canonical))
    return result + extras


def discover_and_evaluate(
    candidate_dir: pathlib.Path,
    baseline_dir: pathlib.Path | None,
    delta_threshold: float,
    channel_tolerance: int,
    backend: str,
) -> list[ScreenEntry]:
    pngs = sorted(candidate_dir.glob("*.png"))
    entries: list[ScreenEntry] = []

    for png_path in pngs:
        stem = png_path.stem
        surface, profile = parse_surface_profile(stem)
        base_path = (baseline_dir / png_path.name) if baseline_dir is not None else None
        if base_path is not None and not base_path.is_file():
            base_path = None
        receipt_path = candidate_dir / f"{stem}.json"
        if not receipt_path.is_file():
            receipt_path = None

        cand_img = ImageRGBA.from_png(png_path, backend=backend)
        base_img = ImageRGBA.from_png(base_path, backend=backend) if base_path is not None else None
        diff = compare_images(base_img, cand_img, channel_tolerance=channel_tolerance)
        receipt = parse_audit_receipt(receipt_path)

        delta_triggered = diff.size_mismatch or (
            diff.delta_ratio is not None and diff.delta_ratio > delta_threshold
        )
        if receipt.total_violations > 0:
            status = "violations"
        elif delta_triggered:
            status = "changed"
        elif not diff.has_baseline:
            status = "new"
        else:
            status = "clean"

        entries.append(
            ScreenEntry(
                surface=surface,
                profile=profile,
                stem=stem,
                candidate_path=png_path,
                baseline_path=base_path,
                receipt_path=receipt_path,
                candidate_img=cand_img,
                baseline_img=base_img,
                diff=diff,
                receipt=receipt,
                status=status,
            )
        )

    surface_order = ordered_names({e.surface for e in entries}, CANONICAL_SURFACES)
    profile_order = ordered_names({e.profile for e in entries}, CANONICAL_PROFILES)
    s_rank = {s: i for i, s in enumerate(surface_order)}
    p_rank = {p: i for i, p in enumerate(profile_order)}
    entries.sort(key=lambda e: (s_rank.get(e.surface, 999), p_rank.get(e.profile, 999), e.stem))
    return entries


# ---------------------------------------------------------------------------
# Artifact Rendering: screen-wall.png & diff-strip.png
# ---------------------------------------------------------------------------

def _status_colors(status: str) -> tuple[tuple[int, int, int, int], tuple[int, int, int, int]]:
    if status == "violations":
        return COL_FAIL, (255, 255, 255, 255)
    if status == "changed":
        return COL_WARN, COL_DARK_TEXT
    if status == "new":
        return COL_NEW, COL_DARK_TEXT
    return COL_PASS, COL_DARK_TEXT


def _pill_label(entry: ScreenEntry) -> str:
    if entry.receipt.total_violations > 0:
        if entry.diff.delta_ratio is not None and entry.diff.delta_ratio > 0:
            return f"{entry.receipt.total_violations} VIOL {entry.diff.delta_ratio * 100:.1f}%"
        return f"{entry.receipt.total_violations} VIOL"
    if entry.diff.size_mismatch:
        return "SIZE DIFF"
    if entry.status == "changed" and entry.diff.delta_ratio is not None:
        return f"Δ{entry.diff.delta_ratio * 100:.2f}%"
    if entry.status == "new":
        return "NEW"
    return "✓ OK"


def render_screen_wall(
    entries: list[ScreenEntry],
    out_path: pathlib.Path,
    thumb_w: int,
    title: str,
    backend: str,
) -> tuple[int, int]:
    surfaces = ordered_names({e.surface for e in entries}, CANONICAL_SURFACES)
    profiles = ordered_names({e.profile for e in entries}, CANONICAL_PROFILES)
    # Keep all 6 canonical trap profile columns visible when any canonical profile is present
    if any(p in CANONICAL_PROFILES for p in profiles):
        extras = [p for p in profiles if p not in CANONICAL_PROFILES]
        profiles = list(CANONICAL_PROFILES) + extras
    if not surfaces:
        canvas = ImageRGBA(720, 140, fill=COL_BG)
        canvas.draw_text(24, 36, title, color=COL_TEXT, scale=2)
        canvas.draw_text(24, 80, "NO CANDIDATE SCREENSHOTS FOUND", color=COL_MUTED, scale=2)
        canvas.save_png(out_path, rgb_only=True, backend=backend)
        return canvas.width, canvas.height

    lookup = {(e.surface, e.profile): e for e in entries}

    # Compute thumbnail height preserving aspect ratios cleanly
    max_thumb_h = int(thumb_w * 2.2)
    thumbs: dict[tuple[str, str], ImageRGBA] = {}
    actual_thumb_h = 120
    for key, entry in lookup.items():
        t = entry.candidate_img.resize_fit(thumb_w, max_thumb_h)
        thumbs[key] = t
        actual_thumb_h = max(actual_thumb_h, t.height)

    pad = 16
    row_label_w = 156
    header_h = 68
    col_header_h = 34
    cell_pad = 10
    pill_bar_h = 28
    cell_w = thumb_w + cell_pad * 2
    cell_h = actual_thumb_h + cell_pad * 2 + pill_bar_h

    total_w = pad * 2 + row_label_w + len(profiles) * (cell_w + pad)
    total_h = pad * 2 + header_h + col_header_h + len(surfaces) * (cell_h + pad)

    canvas = ImageRGBA(total_w, total_h, fill=COL_BG)

    # Top banner
    canvas.fill_rect(0, 0, total_w, header_h, COL_SURFACE)
    canvas.fill_rect(0, header_h - 2, total_w, 2, COL_BORDER)
    canvas.draw_text(pad, 16, title, color=COL_TEXT, scale=2)

    clean_n = sum(1 for e in entries if e.status == "clean")
    changed_n = sum(1 for e in entries if e.status == "changed")
    viol_n = sum(1 for e in entries if e.status == "violations")
    new_n = sum(1 for e in entries if e.status == "new")
    subtitle = (
        f"{len(surfaces)} SURFACES · {len(profiles)} PROFILES · "
        f"{clean_n} OK · {changed_n} CHANGED · {viol_n} VIOL · {new_n} NEW"
    )
    canvas.draw_text(pad, 42, subtitle, color=COL_MUTED, scale=1)

    # Column headers (Trap Profiles)
    col_y = header_h + pad
    canvas.draw_text(pad, col_y + 10, "SURFACE", color=COL_MUTED, scale=1)
    for col_idx, prof in enumerate(profiles):
        cx = pad + row_label_w + col_idx * (cell_w + pad)
        canvas.fill_rounded_rect(cx, col_y, cell_w, col_header_h - 6, 6, COL_ELEVATED)
        canvas.draw_text(cx + 8, col_y + 10, prof, color=COL_TEXT, scale=1, max_width=cell_w - 16)

    # Rows (Surfaces)
    for row_idx, surface in enumerate(surfaces):
        ry = header_h + pad + col_header_h + row_idx * (cell_h + pad)
        canvas.fill_rounded_rect(pad, ry, row_label_w - 12, cell_h, 8, COL_SURFACE)
        canvas.draw_text(pad + 10, ry + 14, surface, color=COL_TEXT, scale=2, max_width=row_label_w - 28)
        row_entries = [lookup[(surface, p)] for p in profiles if (surface, p) in lookup]
        row_viols = sum(e.receipt.total_violations for e in row_entries)
        row_changed = sum(1 for e in row_entries if e.status == "changed")
        canvas.draw_text(pad + 10, ry + 42, f"{len(row_entries)} CAPS", color=COL_MUTED, scale=1)
        if row_viols > 0:
            canvas.draw_pill(pad + 10, ry + 62, f"{row_viols} VIOL", COL_FAIL, (255, 255, 255, 255), scale=1)
        elif row_changed > 0:
            canvas.draw_pill(pad + 10, ry + 62, f"{row_changed} DIFF", COL_WARN, COL_DARK_TEXT, scale=1)
        elif row_entries:
            canvas.draw_pill(pad + 10, ry + 62, "✓ CLEAN", COL_PASS, COL_DARK_TEXT, scale=1)

        for col_idx, prof in enumerate(profiles):
            cx = pad + row_label_w + col_idx * (cell_w + pad)
            entry = lookup.get((surface, prof))
            if entry is None:
                canvas.fill_rounded_rect(cx, ry, cell_w, cell_h, 8, COL_SURFACE)
                canvas.stroke_rect(cx, ry, cell_w, cell_h, COL_BORDER, thickness=1)
                canvas.draw_text(cx + cell_w // 2 - 12, ry + cell_h // 2 - 4, "N/A", color=COL_MUTED, scale=1)
                continue

            border_col, fg_col = _status_colors(entry.status)
            canvas.fill_rounded_rect(cx, ry, cell_w, cell_h, 8, COL_SURFACE)
            canvas.stroke_rect(cx, ry, cell_w, cell_h, border_col, thickness=2)

            thumb = thumbs[(surface, prof)]
            tx = cx + cell_pad + (thumb_w - thumb.width) // 2
            ty = ry + cell_pad + (actual_thumb_h - thumb.height) // 2
            canvas.blit(thumb, tx, ty)

            pill_y = ry + cell_h - pill_bar_h + 4
            canvas.draw_pill(cx + cell_pad, pill_y, _pill_label(entry), border_col, fg_col, scale=1)
            if entry.diff.ssim is not None:
                ssim_txt = f"S:{entry.diff.ssim:.3f}"
                canvas.draw_text(cx + cell_w - cell_pad - len(ssim_txt) * 6, pill_y + 5, ssim_txt, color=COL_MUTED, scale=1)

    canvas.save_png(out_path, rgb_only=True, backend=backend)
    return canvas.width, canvas.height


def render_pair_diff_panel(entry: ScreenEntry, panel_w: int) -> ImageRGBA:
    """Render a 3-column `[BASELINE | CANDIDATE | AMPLIFIED DIFF]` strip for one entry."""
    max_h = int(panel_w * 2.2)
    cand_t = entry.candidate_img.resize_fit(panel_w, max_h)
    diff_t = entry.diff.heatmap.resize_fit(panel_w, max_h)
    if entry.baseline_img is not None:
        base_t = entry.baseline_img.resize_fit(panel_w, max_h)
    else:
        base_t = ImageRGBA(cand_t.width, cand_t.height, fill=COL_ELEVATED)
        base_t.stroke_rect(2, 2, max(1, cand_t.width - 4), max(1, cand_t.height - 4), COL_NEW, thickness=2)
        base_t.draw_text(10, max(8, cand_t.height // 2 - 4), "NO BASELINE", color=COL_NEW, scale=1)

    img_h = max(base_t.height, cand_t.height, diff_t.height)
    pad = 12
    head_h = 38
    sub_h = 20
    w = pad * 4 + panel_w * 3
    h = head_h + sub_h + img_h + pad * 2

    strip = ImageRGBA(w, h, fill=COL_SURFACE)
    border_col, fg_col = _status_colors(entry.status)
    strip.stroke_rect(0, 0, w, h, border_col, thickness=2)
    strip.fill_rect(2, 2, w - 4, head_h - 2, COL_ELEVATED)

    delta_str = f"{entry.diff.delta_ratio * 100:.2f}%" if entry.diff.delta_ratio is not None else "NEW"
    ssim_str = f"{entry.diff.ssim:.4f}" if entry.diff.ssim is not None else "N/A"
    title = f"{entry.surface} / {entry.profile} · Δ {delta_str} · SSIM {ssim_str}"
    strip.draw_text(pad, 13, title, color=COL_TEXT, scale=1, max_width=w - 160)
    pill_txt = _pill_label(entry)
    pill_w = len(pill_txt) * 6 + 14
    strip.draw_pill(w - pad - pill_w, 10, pill_txt, border_col, fg_col, scale=1)

    labels = ("BASELINE", "CANDIDATE (PR)", "AMPLIFIED DIFF HEATMAP")
    panels = (base_t, cand_t, diff_t)
    for idx, (lbl, im) in enumerate(zip(labels, panels)):
        px = pad + idx * (panel_w + pad)
        strip.draw_text(px, head_h + 6, lbl, color=COL_MUTED, scale=1)
        iy = head_h + sub_h + (img_h - im.height) // 2
        ix = px + (panel_w - im.width) // 2
        strip.blit(im, ix, iy)

    return strip


def render_diff_strip(
    entries: list[ScreenEntry],
    out_path: pathlib.Path,
    diffs_dir: pathlib.Path,
    panel_w: int,
    backend: str,
) -> tuple[int, int, int]:
    """Render per-entry diff panels + combined `diff-strip.png` for changed/violating entries."""
    diffs_dir.mkdir(parents=True, exist_ok=True)
    flagged = [e for e in entries if e.status in ("changed", "violations")]

    panels: list[ImageRGBA] = []
    for entry in entries:
        if entry.status in ("changed", "violations") or entry.diff.has_baseline:
            # Always write heatmap/diff PNG for flagged entries (and for any entry with a baseline)
            p_img = render_pair_diff_panel(entry, panel_w=panel_w)
            panel_file = diffs_dir / f"{entry.stem}__diff.png"
            p_img.save_png(panel_file, rgb_only=True, backend=backend)
            entry.diff_panel_path = panel_file
            if entry.status in ("changed", "violations"):
                panels.append(p_img)

    if not panels:
        banner = ImageRGBA(780, 120, fill=COL_BG)
        banner.stroke_rect(2, 2, 776, 116, COL_PASS, thickness=2)
        banner.draw_pill(20, 22, "✓ ALL CLEAR", COL_PASS, COL_DARK_TEXT, scale=2)
        banner.draw_text(20, 72, "0 VISUAL REGRESSIONS AND 0 DESIGN VIOLATIONS DETECTED", color=COL_TEXT, scale=1)
        banner.save_png(out_path, rgb_only=True, backend=backend)
        return banner.width, banner.height, 0

    pad = 16
    header_h = 56
    total_w = max(p.width for p in panels) + pad * 2
    total_h = header_h + pad + sum(p.height + pad for p in panels)

    canvas = ImageRGBA(total_w, total_h, fill=COL_BG)
    canvas.fill_rect(0, 0, total_w, header_h, COL_SURFACE)
    canvas.fill_rect(0, header_h - 2, total_w, 2, COL_BORDER)
    canvas.draw_text(pad, 14, f"CATBIRD VISUAL DIFF STRIP · {len(panels)} FLAGGED", color=COL_TEXT, scale=2)
    canvas.draw_text(pad, 38, "SHOWING ENTRIES EXCEEDING PIXEL DELTA THRESHOLD OR HAVING DESIGN/A11Y VIOLATIONS", color=COL_MUTED, scale=1)

    cy = header_h + pad
    for p in panels:
        canvas.blit(p, pad, cy)
        cy += p.height + pad

    canvas.save_png(out_path, rgb_only=True, backend=backend)
    return canvas.width, canvas.height, len(panels)


# ---------------------------------------------------------------------------
# Artifact Rendering: summary.md & report.json
# ---------------------------------------------------------------------------

def _fmt_pct(ratio: float | None) -> str:
    if ratio is None:
        return "—"
    return f"{ratio * 100:.2f}%"


def _fmt_ssim(ssim: float | None) -> str:
    if ssim is None:
        return "—"
    return f"{ssim:.4f}"


def _status_badge_md(status: str) -> str:
    return {
        "clean": "✅ Clean",
        "new": "🆕 New",
        "changed": "⚠️ Changed",
        "violations": "❌ Violations",
    }.get(status, status)


def build_report_dict(
    entries: list[ScreenEntry],
    delta_threshold: float,
    title: str,
    outputs: dict[str, str],
) -> dict[str, Any]:
    counts_by_cat = {k: sum(e.receipt.counts.get(k, 0) for e in entries) for k in CANONICAL_COUNT_KEYS}
    total_violations = sum(e.receipt.total_violations for e in entries)
    total_errors = sum(e.receipt.error_count for e in entries)
    total_warnings = sum(e.receipt.warning_count for e in entries)
    clean_n = sum(1 for e in entries if e.status == "clean")
    changed_n = sum(1 for e in entries if e.status == "changed")
    viol_n = sum(1 for e in entries if e.status == "violations")
    new_n = sum(1 for e in entries if e.status == "new")

    deltas = [e.diff.delta_ratio for e in entries if e.diff.delta_ratio is not None]
    ssims = [e.diff.ssim for e in entries if e.diff.ssim is not None]
    max_delta = max(deltas) if deltas else 0.0
    min_ssim = min(ssims) if ssims else 1.0

    if viol_n > 0:
        verdict = "violations"
    elif changed_n > 0:
        verdict = "changed"
    elif entries and new_n == len(entries):
        verdict = "bootstrap"
    else:
        verdict = "pass"

    entry_dicts: list[dict[str, Any]] = []
    for e in entries:
        entry_dicts.append(
            {
                "surface": e.surface,
                "profile": e.profile,
                "stem": e.stem,
                "status": e.status,
                "hasBaseline": e.diff.has_baseline,
                "sizeMismatch": e.diff.size_mismatch,
                "baselineSize": list(e.diff.base_size) if e.diff.base_size else None,
                "candidateSize": list(e.diff.cand_size),
                "changedPixels": e.diff.changed_pixels,
                "totalPixels": e.diff.total_pixels,
                "deltaRatio": round(e.diff.delta_ratio, 6) if e.diff.delta_ratio is not None else None,
                "meanAbsDiff": round(e.diff.mean_abs_diff, 6) if e.diff.mean_abs_diff is not None else None,
                "maxChannelDiff": e.diff.max_channel_diff,
                "ssim": round(e.diff.ssim, 6) if e.diff.ssim is not None else None,
                "receiptPresent": e.receipt.present,
                "counts": {**e.receipt.counts, "total": e.receipt.total_violations},
                "errorCount": e.receipt.error_count,
                "warningCount": e.receipt.warning_count,
                "violations": e.receipt.violations,
                "a11yAuditIssues": e.receipt.a11y_audit_issues,
                "metrics": e.receipt.metrics,
                "metadata": e.receipt.metadata,
            }
        )

    return {
        "schemaVersion": 1,
        "title": title,
        "generatedAt": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "deltaThreshold": delta_threshold,
        "verdict": verdict,
        "totals": {
            "entries": len(entries),
            "surfaces": len({e.surface for e in entries}),
            "profiles": len({e.profile for e in entries}),
            "clean": clean_n,
            "changed": changed_n,
            "withViolations": viol_n,
            "new": new_n,
            "totalViolations": total_violations,
            "totalErrors": total_errors,
            "totalWarnings": total_warnings,
            "countsByCategory": counts_by_cat,
            "maxDeltaRatio": round(max_delta, 6),
            "minSsim": round(min_ssim, 6),
        },
        "outputs": outputs,
        "entries": entry_dicts,
    }


def render_summary_markdown(report: dict[str, Any], entries: list[ScreenEntry]) -> str:
    totals = report["totals"]
    verdict = report["verdict"]
    verdict_banner = {
        "pass": "✅ **PASS** — No visual regressions or design/accessibility violations detected.",
        "bootstrap": "🆕 **BASELINE BOOTSTRAP** — No prior baselines found; captured initial reference wall.",
        "changed": f"⚠️ **VISUAL CHANGES DETECTED** — {totals['changed']} screen(s) exceed the {report['deltaThreshold'] * 100:.2f}% pixel delta threshold.",
        "violations": f"❌ **DESIGN / A11Y VIOLATIONS FOUND** — {totals['totalViolations']} violation(s) across {totals['withViolations']} screen(s).",
    }.get(verdict, verdict)

    lines: list[str] = [
        PR_COMMENT_MARKER,
        f"## {report['title']}",
        "",
        verdict_banner,
        "",
        (
            f"**Summary:** {totals['entries']} captures ({totals['surfaces']} surfaces × {totals['profiles']} profiles) · "
            f"✅ {totals['clean']} clean · ⚠️ {totals['changed']} changed · ❌ {totals['withViolations']} with violations · "
            f"🆕 {totals['new']} new · Max Δ `{totals['maxDeltaRatio'] * 100:.2f}%` · Min SSIM `{totals['minSsim']:.4f}`"
        ),
        "",
    ]

    cat = totals["countsByCategory"]
    lines.extend(
        [
            "### Design & Accessibility Audit Totals",
            "",
            "| A11y Audit | Hit Target (<44pt) | Non-appFont | Accent (.blue) | Radius | Off-Grid | Reduce Transp. | Contrast | **Total** |",
            "| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
            (
                f"| {cat['a11yAudit']} | {cat['hitTarget']} | {cat['nonAppFont']} | {cat['accentLeak']} | "
                f"{cat['cornerRadius']} | {cat['offGridSpacing']} | {cat['reduceTransparency']} | "
                f"{cat['surfaceContrast']} | **{totals['totalViolations']}** |"
            ),
            "",
        ]
    )

    def _entry_row(e: ScreenEntry) -> str:
        c = e.receipt.counts
        radius_grid = c["cornerRadius"] + c["offGridSpacing"]
        glass_contrast = c["reduceTransparency"] + c["surfaceContrast"]
        delta_cell = "SIZE DIFF" if e.diff.size_mismatch else _fmt_pct(e.diff.delta_ratio)
        return (
            f"| `{e.surface}` | `{e.profile}` | {_status_badge_md(e.status)} | {delta_cell} | {_fmt_ssim(e.diff.ssim)} | "
            f"{c['a11yAudit']} | {c['hitTarget']} | {c['nonAppFont']} | {c['accentLeak']} | {radius_grid} | {glass_contrast} |"
        )

    table_header = [
        "| Surface | Profile | Status | Pixel Δ | SSIM | A11y Audit | <44pt | Font | Accent | Radius/Grid | Glass/Contrast |",
        "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]

    flagged = [e for e in entries if e.status in ("violations", "changed")]
    clean_or_new = [e for e in entries if e.status not in ("violations", "changed")]

    if flagged:
        lines.append("### Changed & Violating Screens")
        lines.append("")
        lines.extend(table_header)
        lines.extend(_entry_row(e) for e in flagged)
        lines.append("")

        # Violation details for human + AI reviewers
        viol_entries = [e for e in flagged if e.receipt.total_violations > 0]
        if viol_entries:
            lines.append("<details>")
            lines.append(f"<summary>Violation Details ({totals['totalViolations']} total)</summary>")
            lines.append("")
            for e in viol_entries:
                lines.append(f"#### `{e.surface}` · `{e.profile}`")
                for v in e.receipt.violations:
                    sev = v.get("severity", "error").upper()
                    vcat = v.get("category", "other")
                    elem = v.get("element") or v.get("identifier") or v.get("viewClass") or "unknown"
                    msg = v.get("message", "")
                    lines.append(f"- **[{sev}] `{vcat}`** (`{elem}`): {msg}")
                for issue in e.receipt.a11y_audit_issues:
                    atype = issue.get("auditType", "a11y")
                    elem = issue.get("element", "unknown")
                    desc = issue.get("description", "")
                    lines.append(f"- **[A11Y `{atype}`]** (`{elem}`): {desc}")
                lines.append("")
            lines.append("</details>")
            lines.append("")
    else:
        lines.append("_No screens exceeded the pixel delta threshold or recorded violations._")
        lines.append("")

    if clean_or_new:
        lines.append("<details>")
        lines.append(f"<summary>All Clean / New Screens ({len(clean_or_new)})</summary>")
        lines.append("")
        lines.extend(table_header)
        lines.extend(_entry_row(e) for e in clean_or_new)
        lines.append("")
        lines.append("</details>")
        lines.append("")

    lines.append(
        "_Artifacts: `screen-wall.png` (full contact sheet), `diff-strip.png` (flagged side-by-side diffs), "
        "`wall.html` (interactive before/after slider & JSON receipt inspector), `report.json`._"
    )
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Artifact Rendering: Self-Contained Interactive wall.html
# ---------------------------------------------------------------------------

def _img_src(path: pathlib.Path | None, img: ImageRGBA | None, out_dir: pathlib.Path, embed: bool, backend: str) -> str:
    if embed:
        if path is not None and path.is_file():
            b64 = base64.b64encode(path.read_bytes()).decode("ascii")
            return f"data:image/png;base64,{b64}"
        if img is not None:
            b64 = base64.b64encode(img.to_png_bytes(rgb_only=True, backend=backend)).decode("ascii")
            return f"data:image/png;base64,{b64}"
        return ""
    if path is not None:
        return os.path.relpath(path, out_dir)
    return ""


def render_wall_html(
    report: dict[str, Any],
    entries: list[ScreenEntry],
    out_dir: pathlib.Path,
    embed_images: bool,
    backend: str,
) -> str:
    surfaces = ordered_names({e.surface for e in entries}, CANONICAL_SURFACES)
    profiles = ordered_names({e.profile for e in entries}, CANONICAL_PROFILES)

    payload_entries: list[dict[str, Any]] = []
    for idx, (entry, ed) in enumerate(zip(entries, report["entries"])):
        cand_src = _img_src(entry.candidate_path, entry.candidate_img, out_dir, embed_images, backend)
        base_src = _img_src(entry.baseline_path, entry.baseline_img, out_dir, embed_images, backend) if entry.baseline_img else ""
        heat_src = _img_src(None, entry.diff.heatmap, out_dir, True, backend) if embed_images else (
            os.path.relpath(entry.diff_panel_path, out_dir) if entry.diff_panel_path else ""
        )
        item = dict(ed)
        item["index"] = idx
        item["candSrc"] = cand_src
        item["baseSrc"] = base_src
        item["heatSrc"] = heat_src
        item["rawReceipt"] = entry.receipt.raw
        payload_entries.append(item)

    data_json = json.dumps(
        {
            "title": report["title"],
            "generatedAt": report["generatedAt"],
            "verdict": report["verdict"],
            "deltaThreshold": report["deltaThreshold"],
            "totals": report["totals"],
            "surfaces": surfaces,
            "profiles": profiles,
            "entries": payload_entries,
        },
        separators=(",", ":"),
    ).replace("</", "<\\/")

    title_esc = html.escape(report["title"])

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title_esc}</title>
<style>
:root {{
  --bg: #111318;
  --surface: #1D1F26;
  --elevated: #23252D;
  --border: #2E3240;
  --text: #E6E6EC;
  --muted: #A8A8B0;
  --accent: #5192FF;
  --pass: #22C55E;
  --warn: #F59E0B;
  --fail: #EF4444;
  --radius-sm: 8px;
  --radius-md: 12px;
  --radius-lg: 16px;
}}
* {{ box-sizing: border-box; }}
body {{
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
  line-height: 1.45;
}}
header {{
  position: sticky;
  top: 0;
  z-index: 20;
  background: rgba(17, 19, 24, 0.94);
  backdrop-filter: blur(12px);
  border-bottom: 1px solid var(--border);
  padding: 16px 24px;
}}
.header-top {{
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}}
h1 {{
  margin: 0;
  font-size: 20px;
  letter-spacing: -0.02em;
}}
.meta {{ color: var(--muted); font-size: 12px; }}
.kpi-bar {{
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  margin-top: 12px;
}}
.kpi {{
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  padding: 6px 12px;
  font-size: 12px;
}}
.kpi strong {{ font-size: 14px; margin-left: 4px; }}
.controls {{
  display: flex;
  flex-wrap: wrap;
  gap: 10px;
  align-items: center;
  margin-top: 12px;
}}
.chip-group {{ display: flex; flex-wrap: wrap; gap: 6px; }}
.chip {{
  appearance: none;
  border: 1px solid var(--border);
  background: var(--surface);
  color: var(--text);
  border-radius: 999px;
  padding: 6px 12px;
  font-size: 12px;
  cursor: pointer;
  min-height: 32px;
}}
.chip.active {{
  background: var(--accent);
  border-color: var(--accent);
  color: #0B0D12;
  font-weight: 600;
}}
input[type="search"], select {{
  background: var(--surface);
  color: var(--text);
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  padding: 7px 10px;
  font-size: 13px;
}}
main {{ padding: 20px 24px 64px; }}
.grid {{
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(290px, 1fr));
  gap: 16px;
}}
.card {{
  background: var(--surface);
  border: 2px solid var(--border);
  border-radius: var(--radius-md);
  overflow: hidden;
  display: flex;
  flex-direction: column;
}}
.card.status-clean {{ border-color: rgba(34, 197, 94, 0.45); }}
.card.status-new {{ border-color: rgba(81, 146, 255, 0.55); }}
.card.status-changed {{ border-color: var(--warn); }}
.card.status-violations {{ border-color: var(--fail); }}
.card-head {{
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 8px;
  padding: 10px 12px;
  background: var(--elevated);
  border-bottom: 1px solid var(--border);
}}
.card-title {{ font-weight: 600; font-size: 13px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }}
.card-sub {{ font-size: 11px; color: var(--muted); }}
.pill {{
  display: inline-flex;
  align-items: center;
  border-radius: 999px;
  padding: 2px 9px;
  font-size: 11px;
  font-weight: 700;
  white-space: nowrap;
}}
.pill-clean {{ background: var(--pass); color: #0B0D12; }}
.pill-new {{ background: var(--accent); color: #0B0D12; }}
.pill-changed {{ background: var(--warn); color: #0B0D12; }}
.pill-violations {{ background: var(--fail); color: #FFFFFF; }}
.thumb-wrap {{
  position: relative;
  background: #0B0D12;
  padding: 10px;
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 220px;
  max-height: 400px;
  overflow: hidden;
  cursor: pointer;
}}
.thumb-wrap img {{
  max-width: 100%;
  max-height: 380px;
  border-radius: 6px;
  display: block;
}}
.card-metrics {{
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  padding: 8px 12px;
  font-size: 11px;
  color: var(--muted);
  border-top: 1px solid var(--border);
}}
details.receipt-box {{
  border-top: 1px solid var(--border);
  padding: 8px 12px;
  font-size: 12px;
}}
details.receipt-box summary {{ cursor: pointer; color: var(--accent); font-weight: 500; }}
.viol-list {{ list-style: none; padding: 0; margin: 8px 0 0; display: grid; gap: 6px; }}
.viol-item {{
  background: var(--elevated);
  border-left: 3px solid var(--fail);
  padding: 6px 8px;
  border-radius: 4px;
  font-size: 11px;
}}
.viol-item.warn {{ border-left-color: var(--warn); }}
pre.json-dump {{
  background: #0B0D12;
  border: 1px solid var(--border);
  border-radius: 6px;
  padding: 8px;
  overflow-x: auto;
  font-size: 11px;
  max-height: 220px;
}}
/* Modal Lightbox + Before/After Drag Slider */
.modal-backdrop {{
  position: fixed;
  inset: 0;
  background: rgba(8, 10, 14, 0.86);
  display: none;
  align-items: center;
  justify-content: center;
  z-index: 100;
  padding: 20px;
}}
.modal-backdrop.open {{ display: flex; }}
.modal {{
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius-lg);
  width: min(1160px, 100%);
  max-height: 92vh;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}}
.modal-head {{
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 12px 16px;
  background: var(--elevated);
  border-bottom: 1px solid var(--border);
  gap: 10px;
}}
.modal-body {{
  overflow: auto;
  padding: 16px;
  display: grid;
  gap: 16px;
}}
.slider-stage {{
  position: relative;
  margin: 0 auto;
  display: inline-block;
  background: #0B0D12;
  border: 1px solid var(--border);
  border-radius: 8px;
  overflow: hidden;
  user-select: none;
  max-width: 100%;
}}
.slider-stage img {{
  display: block;
  max-height: 62vh;
  max-width: 100%;
  height: auto;
}}
.slider-overlay {{
  position: absolute;
  inset: 0;
  overflow: hidden;
  clip-path: inset(0 calc(100% - var(--split, 50%)) 0 0);
}}
.slider-divider {{
  position: absolute;
  top: 0;
  bottom: 0;
  left: var(--split, 50%);
  width: 2px;
  background: var(--accent);
  pointer-events: none;
}}
.slider-labels {{
  display: flex;
  justify-content: space-between;
  font-size: 11px;
  color: var(--muted);
  margin-top: 6px;
}}
.side-by-side {{
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 12px;
}}
.side-by-side figure {{
  margin: 0;
  background: #0B0D12;
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 8px;
  text-align: center;
}}
.side-by-side figcaption {{ font-size: 11px; color: var(--muted); margin-bottom: 6px; }}
.side-by-side img {{ max-width: 100%; max-height: 55vh; }}
.empty-state {{
  text-align: center;
  padding: 48px;
  color: var(--muted);
  background: var(--surface);
  border-radius: var(--radius-md);
  border: 1px solid var(--border);
}}
</style>
</head>
<body>
<header>
  <div class="header-top">
    <div>
      <h1 id="wall-title">{title_esc}</h1>
      <div class="meta" id="wall-meta"></div>
    </div>
    <span class="pill" id="verdict-pill"></span>
  </div>
  <div class="kpi-bar" id="kpi-bar"></div>
  <div class="controls">
    <div class="chip-group" id="status-chips"></div>
    <div class="chip-group" id="profile-chips"></div>
    <select id="surface-select" aria-label="Filter by surface"></select>
    <input type="search" id="search-input" placeholder="Search surface, profile, violation..." aria-label="Search">
  </div>
</header>
<main>
  <div class="grid" id="card-grid"></div>
</main>

<div class="modal-backdrop" id="modal-backdrop" role="dialog" aria-modal="true">
  <div class="modal">
    <div class="modal-head">
      <div>
        <strong id="modal-title"></strong>
        <span class="meta" id="modal-meta" style="margin-left:8px;"></span>
      </div>
      <div class="chip-group" id="modal-modes">
        <button class="chip active" data-mode="slider">Before / After Slider</button>
        <button class="chip" data-mode="side">Side-by-Side</button>
        <button class="chip" data-mode="diff">Diff Heatmap</button>
        <button class="chip" data-mode="cand">Candidate Only</button>
        <button class="chip" id="modal-close">Close (Esc)</button>
      </div>
    </div>
    <div class="modal-body" id="modal-body"></div>
  </div>
</div>

<script>
const WALL_DATA = {data_json};
const state = {{
  status: "all",
  profile: "all",
  surface: "all",
  query: "",
  modalIndex: null,
  modalMode: "slider",
  split: 50,
}};

function fmtPct(v) {{ return v === null || v === undefined ? "—" : (v * 100).toFixed(2) + "%"; }}
function fmtSsim(v) {{ return v === null || v === undefined ? "—" : Number(v).toFixed(4); }}
function esc(s) {{
  return String(s ?? "").replace(/[&<>"']/g, c => ({{"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}}[c]));
}}
function pillClass(st) {{
  if (st === "violations") return "pill-violations";
  if (st === "changed") return "pill-changed";
  if (st === "new") return "pill-new";
  return "pill-clean";
}}
function pillText(e) {{
  if (e.counts && e.counts.total > 0) return e.counts.total + " VIOL";
  if (e.sizeMismatch) return "SIZE DIFF";
  if (e.status === "changed") return "Δ " + fmtPct(e.deltaRatio);
  if (e.status === "new") return "NEW";
  return "✓ CLEAN";
}}

function renderHeader() {{
  const t = WALL_DATA.totals;
  document.getElementById("wall-meta").textContent =
    `Generated ${{WALL_DATA.generatedAt}} · Delta threshold ${{(WALL_DATA.deltaThreshold * 100).toFixed(2)}}%`;
  const vp = document.getElementById("verdict-pill");
  const vMap = {{
    pass: ["pill-clean", "PASS"],
    bootstrap: ["pill-new", "BOOTSTRAP"],
    changed: ["pill-changed", "VISUAL CHANGES"],
    violations: ["pill-violations", "VIOLATIONS FOUND"],
  }};
  const [cls, lbl] = vMap[WALL_DATA.verdict] || ["pill-clean", WALL_DATA.verdict];
  vp.className = "pill " + cls;
  vp.textContent = lbl;

  const kpis = [
    ["Captures", t.entries],
    ["Clean", t.clean],
    ["Changed", t.changed],
    ["Violations", t.totalViolations],
    ["New", t.new],
    ["Max Δ", fmtPct(t.maxDeltaRatio)],
    ["Min SSIM", fmtSsim(t.minSsim)],
  ];
  document.getElementById("kpi-bar").innerHTML = kpis
    .map(([k, v]) => `<div class="kpi">${{esc(k)}}<strong>${{esc(v)}}</strong></div>`).join("");

  const statuses = [["all", "All"], ["violations", "Violations"], ["changed", "Changed"], ["clean", "Clean"], ["new", "New"]];
  document.getElementById("status-chips").innerHTML = statuses
    .map(([k, l]) => `<button class="chip ${{state.status === k ? "active" : ""}}" data-status="${{k}}">${{l}}</button>`).join("");

  const profiles = [["all", "All Profiles"], ...WALL_DATA.profiles.map(p => [p, p])];
  document.getElementById("profile-chips").innerHTML = profiles
    .map(([k, l]) => `<button class="chip ${{state.profile === k ? "active" : ""}}" data-profile="${{esc(k)}}">${{esc(l)}}</button>`).join("");

  const sel = document.getElementById("surface-select");
  sel.innerHTML = `<option value="all">All Surfaces (${{WALL_DATA.surfaces.length}})</option>` +
    WALL_DATA.surfaces.map(s => `<option value="${{esc(s)}}" ${{state.surface === s ? "selected" : ""}}>${{esc(s)}}</option>`).join("");
}}

function filteredEntries() {{
  const q = state.query.trim().toLowerCase();
  return WALL_DATA.entries.filter(e => {{
    if (state.status !== "all" && e.status !== state.status) return false;
    if (state.profile !== "all" && e.profile !== state.profile) return false;
    if (state.surface !== "all" && e.surface !== state.surface) return false;
    if (q) {{
      const blob = (e.surface + " " + e.profile + " " + JSON.stringify(e.violations || []) + " " + JSON.stringify(e.a11yAuditIssues || [])).toLowerCase();
      if (!blob.includes(q)) return false;
    }}
    return true;
  }});
}}

function renderViolationsHtml(e) {{
  const items = [];
  for (const v of (e.violations || [])) {{
    const cls = (v.severity === "warning" || v.severity === "warn") ? "warn" : "";
    const elem = v.element || v.identifier || v.viewClass || "";
    const frame = v.frame ? ` [${{v.frame.x}},${{v.frame.y}} ${{v.frame.width}}×${{v.frame.height}}]` : "";
    items.push(`<li class="viol-item ${{cls}}"><strong>[${{esc((v.severity||"error").toUpperCase())}}] ${{esc(v.category)}}</strong> ${{esc(elem)}}${{esc(frame)}}<br>${{esc(v.message)}}</li>`);
  }}
  for (const a of (e.a11yAuditIssues || [])) {{
    items.push(`<li class="viol-item"><strong>[A11Y ${{esc(a.auditType || "audit")}}]</strong> ${{esc(a.element || "")}}<br>${{esc(a.description || "")}}</li>`);
  }}
  if (!items.length) return `<div class="meta" style="margin-top:6px;">No recorded violations.</div>`;
  return `<ul class="viol-list">${{items.join("")}}</ul>`;
}}

function renderGrid() {{
  const grid = document.getElementById("card-grid");
  const list = filteredEntries();
  if (!list.length) {{
    grid.innerHTML = `<div class="empty-state">No screens match the current filters.</div>`;
    return;
  }}
  grid.innerHTML = list.map(e => `
    <article class="card status-${{esc(e.status)}}">
      <div class="card-head">
        <div>
          <div class="card-title">${{esc(e.surface)}}</div>
          <div class="card-sub">${{esc(e.profile)}}</div>
        </div>
        <span class="pill ${{pillClass(e.status)}}">${{esc(pillText(e))}}</span>
      </div>
      <div class="thumb-wrap" data-open="${{e.index}}" title="Click to inspect before/after & diff">
        <img src="${{e.candSrc}}" alt="${{esc(e.surface)}} ${{esc(e.profile)}}" loading="lazy">
      </div>
      <div class="card-metrics">
        <span>Δ <strong>${{fmtPct(e.deltaRatio)}}</strong></span>
        <span>SSIM <strong>${{fmtSsim(e.ssim)}}</strong></span>
        <span>${{e.candidateSize[0]}}×${{e.candidateSize[1]}}</span>
        <span>A11y: <strong>${{e.counts.a11yAudit}}</strong></span>
        <span>&lt;44pt: <strong>${{e.counts.hitTarget}}</strong></span>
      </div>
      <details class="receipt-box">
        <summary>Audit Receipt (${{e.counts.total}} violation${{e.counts.total === 1 ? "" : "s"}})</summary>
        ${{renderViolationsHtml(e)}}
        <pre class="json-dump">${{esc(JSON.stringify(e.receiptPresent ? e.rawReceipt : e.counts, null, 2))}}</pre>
      </details>
    </article>
  `).join("");
}}

function renderModal() {{
  const backdrop = document.getElementById("modal-backdrop");
  if (state.modalIndex === null) {{
    backdrop.classList.remove("open");
    return;
  }}
  const e = WALL_DATA.entries[state.modalIndex];
  backdrop.classList.add("open");
  document.getElementById("modal-title").textContent = `${{e.surface}} / ${{e.profile}}`;
  document.getElementById("modal-meta").textContent =
    `Δ ${{fmtPct(e.deltaRatio)}} · SSIM ${{fmtSsim(e.ssim)}} · ${{e.counts.total}} violation(s)`;
  document.querySelectorAll("#modal-modes [data-mode]").forEach(btn => {{
    btn.classList.toggle("active", btn.dataset.mode === state.modalMode);
  }});

  let visual = "";
  if (state.modalMode === "slider") {{
    if (e.baseSrc) {{
      visual = `
        <div style="text-align:center;">
          <div class="slider-stage" id="slider-stage" style="--split:${{state.split}}%;">
            <img src="${{e.candSrc}}" alt="Candidate">
            <div class="slider-overlay"><img src="${{e.baseSrc}}" alt="Baseline"></div>
            <div class="slider-divider"></div>
          </div>
          <div style="max-width:460px;margin:10px auto 0;">
            <input type="range" id="split-range" min="0" max="100" value="${{state.split}}" style="width:100%;">
            <div class="slider-labels"><span>← Baseline (Left)</span><span id="split-val">${{state.split}}%</span><span>Candidate / PR (Right) →</span></div>
          </div>
        </div>`;
    }} else {{
      visual = `<div style="text-align:center;"><div class="meta" style="margin-bottom:8px;">No baseline image yet (bootstrap capture)</div><img src="${{e.candSrc}}" style="max-height:60vh;max-width:100%;border-radius:8px;"></div>`;
    }}
  }} else if (state.modalMode === "side") {{
    visual = `<div class="side-by-side">
      <figure><figcaption>Baseline</figcaption>${{e.baseSrc ? `<img src="${{e.baseSrc}}">` : `<div class="meta">No baseline</div>`}}</figure>
      <figure><figcaption>Candidate (PR)</figcaption><img src="${{e.candSrc}}"></figure>
      <figure><figcaption>Amplified Diff Heatmap</figcaption><img src="${{e.heatSrc}}"></figure>
    </div>`;
  }} else if (state.modalMode === "diff") {{
    visual = `<div style="text-align:center;"><img src="${{e.heatSrc}}" style="max-height:62vh;max-width:100%;border-radius:8px;"></div>`;
  }} else {{
    visual = `<div style="text-align:center;"><img src="${{e.candSrc}}" style="max-height:62vh;max-width:100%;border-radius:8px;"></div>`;
  }}

  const metaBits = Object.entries(e.metadata || {{}}).map(([k, v]) =>
    `<span class="kpi">${{esc(k)}}: <strong>${{esc(typeof v === "object" ? JSON.stringify(v) : v)}}</strong></span>`
  ).join("");

  document.getElementById("modal-body").innerHTML = `
    ${{visual}}
    ${{metaBits ? `<div class="kpi-bar">${{metaBits}}</div>` : ""}}
    <div>
      <strong>Design & Accessibility Audit (${{e.counts.total}})</strong>
      ${{renderViolationsHtml(e)}}
      <details style="margin-top:10px;">
        <summary style="cursor:pointer;color:var(--accent);font-size:12px;">Raw JSON Receipt</summary>
        <pre class="json-dump">${{esc(JSON.stringify(e.receiptPresent ? e.rawReceipt : e, null, 2))}}</pre>
      </details>
    </div>
  `;

  const range = document.getElementById("split-range");
  const stage = document.getElementById("slider-stage");
  if (range && stage) {{
    const applySplit = (val) => {{
      state.split = Math.max(0, Math.min(100, Number(val)));
      stage.style.setProperty("--split", state.split + "%");
      range.value = state.split;
      const lbl = document.getElementById("split-val");
      if (lbl) lbl.textContent = Math.round(state.split) + "%";
    }};
    range.addEventListener("input", ev => applySplit(ev.target.value));
    stage.addEventListener("pointerdown", ev => {{
      const update = (pe) => {{
        const rect = stage.getBoundingClientRect();
        if (rect.width > 0) applySplit(((pe.clientX - rect.left) / rect.width) * 100);
      }};
      update(ev);
      const onMove = (pe) => update(pe);
      const onUp = () => {{ window.removeEventListener("pointermove", onMove); window.removeEventListener("pointerup", onUp); }};
      window.addEventListener("pointermove", onMove);
      window.addEventListener("pointerup", onUp);
    }});
  }}
}}

document.getElementById("status-chips").addEventListener("click", ev => {{
  const btn = ev.target.closest("[data-status]");
  if (!btn) return;
  state.status = btn.dataset.status;
  renderHeader();
  renderGrid();
}});
document.getElementById("profile-chips").addEventListener("click", ev => {{
  const btn = ev.target.closest("[data-profile]");
  if (!btn) return;
  state.profile = btn.dataset.profile;
  renderHeader();
  renderGrid();
}});
document.getElementById("surface-select").addEventListener("change", ev => {{
  state.surface = ev.target.value;
  renderGrid();
}});
document.getElementById("search-input").addEventListener("input", ev => {{
  state.query = ev.target.value;
  renderGrid();
}});
document.getElementById("card-grid").addEventListener("click", ev => {{
  const wrap = ev.target.closest("[data-open]");
  if (!wrap) return;
  state.modalIndex = Number(wrap.dataset.open);
  renderModal();
}});
document.getElementById("modal-modes").addEventListener("click", ev => {{
  const btn = ev.target.closest("[data-mode]");
  if (!btn) return;
  state.modalMode = btn.dataset.mode;
  renderModal();
}});
document.getElementById("modal-close").addEventListener("click", () => {{
  state.modalIndex = null;
  renderModal();
}});
document.getElementById("modal-backdrop").addEventListener("click", ev => {{
  if (ev.target.id === "modal-backdrop") {{
    state.modalIndex = null;
    renderModal();
  }}
}});
document.addEventListener("keydown", ev => {{
  if (state.modalIndex === null) return;
  if (ev.key === "Escape") {{ state.modalIndex = null; renderModal(); }}
  else if (ev.key === "ArrowRight") {{ state.modalIndex = (state.modalIndex + 1) % WALL_DATA.entries.length; renderModal(); }}
  else if (ev.key === "ArrowLeft") {{ state.modalIndex = (state.modalIndex - 1 + WALL_DATA.entries.length) % WALL_DATA.entries.length; renderModal(); }}
}});

renderHeader();
renderGrid();
</script>
</body>
</html>
"""


# ---------------------------------------------------------------------------
# CLI Entrypoint
# ---------------------------------------------------------------------------

def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build Catbird Visual QA Screen Wall, diff strip, HTML viewer & CI report."
    )
    parser.add_argument("--candidate", required=True, type=pathlib.Path, help="Directory with <surface>__<profile>.png + optional .json receipts")
    parser.add_argument("--baseline", type=pathlib.Path, default=None, help="Optional directory with baseline PNGs")
    parser.add_argument("--out", required=True, type=pathlib.Path, help="Output directory for wall artifacts")
    parser.add_argument("--delta-threshold", type=float, default=0.001, help="Changed-pixel ratio threshold (default 0.001 = 0.1%%)")
    parser.add_argument("--channel-tolerance", type=int, default=2, help="Per-channel LSB tolerance 0..255 (default 2)")
    parser.add_argument("--thumb-width", type=int, default=220, help="Thumbnail width on screen-wall.png (default 220)")
    parser.add_argument("--panel-width", type=int, default=280, help="Per-panel width on diff-strip.png (default 280)")
    parser.add_argument("--title", default="Catbird iOS Visual QA Screen Wall", help="Report header title")
    parser.add_argument("--backend", choices=("auto", "stdlib", "pil"), default="auto", help="PNG codec backend")
    parser.add_argument("--no-embed-images", action="store_true", help="Reference PNG paths instead of embedding base64 in wall.html")
    parser.add_argument("--fail-on-violations", action="store_true", help="Exit non-zero if any design/a11y violation is recorded")
    parser.add_argument("--fail-on-delta", action="store_true", help="Exit non-zero if any screen exceeds --delta-threshold or mismatches size")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if not args.candidate.is_dir():
        print(f"error: candidate directory does not exist: {args.candidate}", file=sys.stderr)
        return 1

    baseline_dir = args.baseline if (args.baseline is not None and args.baseline.is_dir()) else None
    args.out.mkdir(parents=True, exist_ok=True)

    entries = discover_and_evaluate(
        candidate_dir=args.candidate,
        baseline_dir=baseline_dir,
        delta_threshold=args.delta_threshold,
        channel_tolerance=args.channel_tolerance,
        backend=args.backend,
    )

    wall_png = args.out / "screen-wall.png"
    diff_png = args.out / "diff-strip.png"
    diffs_dir = args.out / "diffs"
    wall_html = args.out / "wall.html"
    summary_md = args.out / "summary.md"
    report_json = args.out / "report.json"

    render_screen_wall(entries, wall_png, thumb_w=args.thumb_width, title=args.title, backend=args.backend)
    render_diff_strip(entries, diff_png, diffs_dir=diffs_dir, panel_w=args.panel_width, backend=args.backend)

    outputs = {
        "screenWallPng": wall_png.name,
        "diffStripPng": diff_png.name,
        "wallHtml": wall_html.name,
        "summaryMd": summary_md.name,
        "reportJson": report_json.name,
    }
    report = build_report_dict(entries, delta_threshold=args.delta_threshold, title=args.title, outputs=outputs)

    summary_md.write_text(render_summary_markdown(report, entries), encoding="utf-8")
    report_json.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    wall_html.write_text(
        render_wall_html(
            report,
            entries,
            out_dir=args.out,
            embed_images=not args.no_embed_images,
            backend=args.backend,
        ),
        encoding="utf-8",
    )

    totals = report["totals"]
    print(
        f"[screen-wall] verdict={report['verdict']} entries={totals['entries']} "
        f"clean={totals['clean']} changed={totals['changed']} "
        f"violations={totals['totalViolations']} new={totals['new']} "
        f"out={args.out}"
    )

    failed_violations = args.fail_on_violations and totals["totalViolations"] > 0
    failed_delta = args.fail_on_delta and (
        totals["changed"] > 0
        or any(
            e.diff.size_mismatch or (e.diff.delta_ratio is not None and e.diff.delta_ratio > args.delta_threshold)
            for e in entries
        )
    )
    if failed_violations and failed_delta:
        return 4
    if failed_violations:
        return 2
    if failed_delta:
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
