#!/usr/bin/env python3
"""Draws every file in assets/ from two fonts.

    python3 dev/logo/build.py            # writes assets/
    python3 dev/logo/build.py --out DIR  # writes somewhere else

Needs fontTools, uharfbuzz, cairosvg and Pillow (`pip install -r dev/logo/requirements.txt`).
The two fonts are fetched from google/fonts into dev/logo/fonts/ on first run; nothing else is
downloaded and no font needs to be installed. Every glyph is shaped with HarfBuzz and outlined
into the SVGs, so the output renders the same everywhere.

The system is the one Latu's assets/README.md describes; sizes and colours are the constants
below. Rupa's own assets/README.md says what each file is for.
"""

from __future__ import annotations

import argparse
import functools
import io
import sys
import urllib.request
from pathlib import Path

import cairosvg
import uharfbuzz as hb
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from PIL import Image

# =====
# Constants
# =====

NAME = "rupa"
LATIN = "Rupa"
JAVANESE = "ꦫꦸꦥ"  # ꦫꦸꦥ  ra, suku, pa
MARK = "ꦫ"  # ꦫ  ra — the first letter, as Latu's mark is ꦭ

# Ink, Deep, Mid, Bright, Glow, Ember — Latu's six roles at Latu's OKLCH lightness and chroma,
# turned from purple (hue 310) to teal (hue 185) with the chroma pulled in to three quarters.
PALETTE = {
    "ink": "#002C28",
    "deep": "#00443E",
    "mid": "#236760",
    "bright": "#02887E",
    "glow": "#2EADA0",
    "ember": "#6ECFC3",
}
WHITE = "#FFFFFF"

# Latin: Outfit Medium, tracking -2/1000. Javanese: Noto Sans Javanese, Regular in the lockups
# and Bold for the mark so it holds at 16 px.
FONTS_DIR = Path(__file__).resolve().parent / "fonts"
GOOGLE_FONTS = "https://raw.githubusercontent.com/google/fonts/main/ofl"
LATIN_FONT = ("Outfit[wght].ttf", f"{GOOGLE_FONTS}/outfit/Outfit%5Bwght%5D.ttf")
JAVANESE_FONT = (
    "NotoSansJavanese[wght].ttf",
    f"{GOOGLE_FONTS}/notosansjavanese/NotoSansJavanese%5Bwght%5D.ttf",
)
LATIN_WEIGHT = 500
JAVANESE_WEIGHT = 400
MARK_WEIGHT = 700
TRACKING = -2 / 1000

# Lockup geometry, in SVG user units. The image is centred on the middle of the Latin x-height;
# the Javanese letters are sized so their body height equals that x-height and share the
# baseline, so the suku hangs below into the lower half.
CAP_HEIGHT = 39.2
LOCKUP_HEIGHT = 125
PAD_X = 8
DIVIDER_GAP = 22  # ink to divider, each side
DIVIDER_WIDTH = 1.5
DIVIDER_OPACITY = 0.5

# Stacked: Latin over Javanese, both centred, on a 140-tall canvas like Latu's.
STACKED_CAP_HEIGHT = 40.6
STACKED_GAP = 14  # Latin baseline to Javanese top
STACKED_PAD = 8

# Tile (avatar, favicon) and bare mark, both on 100 × 100.
TILE_RADIUS = 22
TILE_INK_WIDTH = 72
MARK_INK_WIDTH = 90
TILE_IN_LOCKUP_SCALE = 0.439  # tile height beside the lockup, as a fraction of 100
TILE_IN_LOCKUP_GAP = 8

PNG_LOCKUP_WIDTH = 1200
AVATAR_SIZES = (512, 256, 128)
FAVICON_SIZES = (16, 32, 48)


# =====
# Fonts
# =====


def fetch_fonts() -> None:
    FONTS_DIR.mkdir(parents=True, exist_ok=True)
    for name, url in (LATIN_FONT, JAVANESE_FONT):
        path = FONTS_DIR / name
        if path.exists():
            continue
        print(f"fetching {name}", file=sys.stderr)
        with urllib.request.urlopen(url, timeout=60) as response:
            path.write_bytes(response.read())


@functools.lru_cache(maxsize=None)
def face(path: Path, weight: int) -> "Face":
    return Face(path, weight)


class Face:
    """A static instance of a variable font, shaped by HarfBuzz and drawn by fontTools."""

    def __init__(self, path: Path, weight: int):
        variable = TTFont(path)
        static = instantiateVariableFont(variable, {"wght": weight}, inplace=False)
        data = io.BytesIO()
        static.save(data)
        self.data = data.getvalue()
        self.tt = TTFont(io.BytesIO(self.data))
        self.glyph_set = self.tt.getGlyphSet()
        self.glyph_order = self.tt.getGlyphOrder()
        self.upem = self.tt["head"].unitsPerEm
        self.cap_height = self.tt["OS/2"].sCapHeight / self.upem
        self.x_height = self.tt["OS/2"].sxHeight / self.upem
        self.version = self.tt["name"].getDebugName(5)
        self.hb_font = hb.Font(hb.Face(self.data))

    def shape(self, text: str):
        buf = hb.Buffer()
        buf.add_str(text)
        buf.guess_segment_properties()
        hb.shape(self.hb_font, buf)
        return list(zip(buf.glyph_infos, buf.glyph_positions))

    def body_height(self, text: str) -> float:
        """Height of the tallest base letter in `text`, as a fraction of the em."""
        top = 0
        for info, _ in self.shape(text):
            bounds = self.bounds(info.codepoint)
            if bounds:
                top = max(top, bounds[3])
        return top / self.upem

    def bounds(self, gid: int):
        pen = BoundsPen(self.glyph_set)
        self.glyph_set[self.glyph_order[gid]].draw(pen)
        return pen.bounds


class Run:
    """A word shaped at a size: glyph placements in user units, pen at (0, 0) on the baseline."""

    def __init__(self, face: Face, text: str, size: float, tracking: float = 0.0):
        self.face = face
        self.scale = size / face.upem
        self.glyphs: list[tuple[str, float, float]] = []  # name, x, y (SVG y grows downward)
        x = 0.0
        xmin = ymin = float("inf")
        xmax = ymax = float("-inf")
        for info, pos in face.shape(text):
            bounds = face.bounds(info.codepoint)
            gx = x + pos.x_offset * self.scale
            gy = -pos.y_offset * self.scale
            if bounds:
                self.glyphs.append((face.glyph_order[info.codepoint], gx, gy))
                xmin = min(xmin, gx + bounds[0] * self.scale)
                xmax = max(xmax, gx + bounds[2] * self.scale)
                ymin = min(ymin, gy - bounds[3] * self.scale)
                ymax = max(ymax, gy - bounds[1] * self.scale)
            x += pos.x_advance * self.scale + tracking * size
        self.ink = (xmin, ymin, xmax, ymax)

    @property
    def width(self) -> float:
        return self.ink[2] - self.ink[0]

    @property
    def height(self) -> float:
        return self.ink[3] - self.ink[1]

    def path(self, fill: str, dx: float = 0.0, dy: float = 0.0) -> str:
        """One path for the whole word, with the pen origin moved to (dx, dy)."""
        pen = SVGPathPen(self.face.glyph_set, ntos=_ntos)
        for name, gx, gy in self.glyphs:
            transform = (self.scale, 0, 0, -self.scale, gx + dx, gy + dy)
            self.face.glyph_set[name].draw(TransformPen(pen, transform))
        return f'<path d="{pen.getCommands()}" fill="{fill}"/>'


def _ntos(value: float) -> str:
    text = f"{value:.2f}".rstrip("0").rstrip(".")
    return "0" if text in ("", "-0") else text


# =====
# Drawings
# =====


def svg(width: float, height: float, body: str, defs: str = "") -> str:
    w, h = _ntos(width), _ntos(height)
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}">\n'
        f"<defs>{defs}</defs>\n{body}\n</svg>\n"
    )


def gradient(gid: str, stops: list[str], x2: float = 0.0, y2: float = 0.0) -> str:
    # From the base up ("lit from below") unless x2/y2 say otherwise.
    offsets = [0, 0.45, 1] if len(stops) == 3 else [k / (len(stops) - 1) for k in range(len(stops))]
    inner = "".join(
        f'<stop offset="{_ntos(o)}" stop-color="{c}"/>' for o, c in zip(offsets, stops)
    )
    return f'<linearGradient id="{gid}" x1="0" y1="1" x2="{_ntos(x2)}" y2="{_ntos(y2)}">{inner}</linearGradient>'


class Identity:
    def __init__(self, palette: dict[str, str], latin: str, javanese: str, mark: str):
        fetch_fonts()
        self.p = palette
        self.latin_face = face(FONTS_DIR / LATIN_FONT[0], LATIN_WEIGHT)
        self.javanese_face = face(FONTS_DIR / JAVANESE_FONT[0], JAVANESE_WEIGHT)
        self.mark_face = face(FONTS_DIR / JAVANESE_FONT[0], MARK_WEIGHT)
        self.latin_text, self.javanese_text, self.mark_text = latin, javanese, mark

    # -- lockup -------------------------------------------------------------------------------

    def _pair(self, cap_height: float) -> tuple[Run, Run, float, float]:
        """Latin and Javanese runs sized to share a baseline, plus the x-height and baseline y."""
        latin_size = cap_height / self.latin_face.cap_height
        x_height = self.latin_face.x_height * latin_size
        javanese_size = x_height / self.javanese_face.body_height(self.javanese_text)
        latin = Run(self.latin_face, self.latin_text, latin_size, TRACKING)
        javanese = Run(self.javanese_face, self.javanese_text, javanese_size)
        return latin, javanese, x_height, latin_size

    def _lockup(self, dark: bool, dx: float = 0.0) -> tuple[str, float, float]:
        """Lockup body starting `dx` in from the left; returns (body, width, baseline)."""
        latin, javanese, x_height, _ = self._pair(CAP_HEIGHT)
        baseline = LOCKUP_HEIGHT / 2 + x_height / 2
        latin_x = dx + PAD_X - latin.ink[0]
        divider_x = dx + PAD_X + latin.width + DIVIDER_GAP
        javanese_x = divider_x + DIVIDER_WIDTH + DIVIDER_GAP - javanese.ink[0]
        width = javanese_x + javanese.ink[2] + PAD_X
        latin_fill = WHITE if dark else self.p["deep"]
        javanese_fill = self.p["glow"] if dark else self.p["mid"]
        body = (
            latin.path(latin_fill, latin_x, baseline)
            + f'<rect x="{_ntos(divider_x)}" y="{_ntos(baseline - CAP_HEIGHT)}" '
            f'width="{_ntos(DIVIDER_WIDTH)}" height="{_ntos(CAP_HEIGHT)}" '
            f'fill="{javanese_fill}" opacity="{_ntos(DIVIDER_OPACITY)}"/>'
            + javanese.path(javanese_fill, javanese_x, baseline)
        )
        return body, width, baseline

    def lockup(self, dark: bool = False) -> str:
        body, width, _ = self._lockup(dark)
        return svg(round(width), LOCKUP_HEIGHT, body)

    def lockup_with_mark(self, dark: bool = False) -> str:
        tile_size = 100 * TILE_IN_LOCKUP_SCALE
        shift = 4 + tile_size + TILE_IN_LOCKUP_GAP
        body, width, baseline = self._lockup(dark, dx=shift)
        tile_y = baseline - CAP_HEIGHT / 2 - tile_size / 2  # level with the Latin caps
        tile = (
            f'<g transform="translate(4 {_ntos(tile_y)}) scale({_ntos(TILE_IN_LOCKUP_SCALE)})">'
            + self._tile_body()
            + "</g>"
        )
        return svg(round(width), LOCKUP_HEIGHT, tile + body, self._tile_defs())

    def lockup_stacked(self, dark: bool = False) -> str:
        latin, javanese, _, _ = self._pair(STACKED_CAP_HEIGHT)
        width = max(latin.width, javanese.width) + 2 * STACKED_PAD
        latin_baseline = STACKED_PAD + STACKED_CAP_HEIGHT
        javanese_baseline = latin_baseline + STACKED_GAP - javanese.ink[1]
        height = javanese_baseline + javanese.ink[3] + STACKED_PAD
        latin_fill = WHITE if dark else self.p["deep"]
        javanese_fill = self.p["glow"] if dark else self.p["mid"]
        body = latin.path(
            latin_fill, (width - latin.width) / 2 - latin.ink[0], latin_baseline
        ) + javanese.path(
            javanese_fill, (width - javanese.width) / 2 - javanese.ink[0], javanese_baseline
        )
        return svg(round(width), round(height), body)

    # -- mark and tile --------------------------------------------------------------------------

    def _mark_run(self, ink_width: float) -> tuple[Run, float, float]:
        """The mark letter scaled to `ink_width` and centred on a 100 × 100 canvas."""
        probe = Run(self.mark_face, self.mark_text, 100)
        size = 100 * ink_width / probe.width
        run = Run(self.mark_face, self.mark_text, size)
        dx = (100 - run.width) / 2 - run.ink[0]
        dy = (100 - run.height) / 2 - run.ink[1]
        return run, dx, dy

    def mark(self, variant: str = "light") -> str:
        run, dx, dy = self._mark_run(MARK_INK_WIDTH)
        if variant == "light":
            defs = gradient("m", [self.p["bright"], self.p["mid"], self.p["deep"]])
            fill = "url(#m)"
        elif variant == "dark":
            defs = gradient("m", [self.p["ember"], self.p["glow"], self.p["bright"]])
            fill = "url(#m)"
        elif variant == "mono":
            defs, fill = "", self.p["deep"]
        elif variant == "white":
            defs, fill = "", WHITE
        else:
            raise ValueError(variant)
        return svg(100, 100, run.path(fill, dx, dy), defs)

    def _tile_defs(self) -> str:
        return gradient("avt", [self.p["ink"], self.p["deep"]], x2=1, y2=0)

    def _tile_body(self) -> str:
        run, dx, dy = self._mark_run(TILE_INK_WIDTH)
        return (
            f'<rect width="100" height="100" rx="{TILE_RADIUS}" fill="url(#avt)"/>'
            + run.path(self.p["ember"], dx, dy)
        )

    def tile(self) -> str:
        return svg(100, 100, self._tile_body(), self._tile_defs())


# =====
# Rasters
# =====


def png(svg_text: str, width: int | None = None, height: int | None = None) -> bytes:
    return cairosvg.svg2png(
        bytestring=svg_text.encode(), output_width=width, output_height=height
    )


def ico(svg_text: str, sizes: tuple[int, ...]) -> bytes:
    # Largest first: Pillow drops any size larger than the image it is handed as the base.
    ordered = sorted(sizes, reverse=True)
    images = [Image.open(io.BytesIO(png(svg_text, s, s))).convert("RGBA") for s in ordered]
    out = io.BytesIO()
    images[0].save(out, format="ICO", append_images=images[1:], sizes=[(s, s) for s in ordered])
    return out.getvalue()


# =====
# Files
# =====


def build(out: Path, identity: Identity) -> list[Path]:
    out.mkdir(parents=True, exist_ok=True)
    files: dict[str, bytes] = {}
    n = NAME

    for dark, suffix in ((False, ""), (True, "-dark")):
        lockup = identity.lockup(dark)
        files[f"{n}-lockup{suffix}.svg"] = lockup.encode()
        files[f"{n}-lockup{suffix}@2x.png"] = png(lockup, width=PNG_LOCKUP_WIDTH)
        files[f"{n}-lockup-with-mark{suffix}.svg"] = identity.lockup_with_mark(dark).encode()
        files[f"{n}-lockup-stacked{suffix}.svg"] = identity.lockup_stacked(dark).encode()

    files[f"{n}-mark.svg"] = identity.mark("light").encode()
    files[f"{n}-mark-ondark.svg"] = identity.mark("dark").encode()
    files[f"{n}-mark-mono.svg"] = identity.mark("mono").encode()
    files[f"{n}-mark-white.svg"] = identity.mark("white").encode()

    tile = identity.tile()
    files[f"{n}-avatar.svg"] = tile.encode()
    for size in AVATAR_SIZES:
        files[f"{n}-avatar-{size}.png"] = png(tile, size, size)
    files["favicon.svg"] = tile.encode()
    for size in FAVICON_SIZES:
        files[f"favicon-{size}.png"] = png(tile, size, size)
    files["favicon.ico"] = ico(tile, FAVICON_SIZES)

    written = []
    for name, data in files.items():
        path = out / name
        path.write_bytes(data)
        written.append(path)
    return written


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    default_out = Path(__file__).resolve().parents[2] / "assets"
    parser.add_argument("--out", type=Path, default=default_out, help=f"default: {default_out}")
    args = parser.parse_args()
    identity = Identity(PALETTE, LATIN, JAVANESE, MARK)
    print(
        f"Outfit {identity.latin_face.version}; Noto Sans Javanese {identity.javanese_face.version}",
        file=sys.stderr,
    )
    for path in build(args.out, identity):
        print(path.relative_to(Path.cwd()) if path.is_relative_to(Path.cwd()) else path)


if __name__ == "__main__":
    main()
