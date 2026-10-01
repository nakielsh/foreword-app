#!/usr/bin/env python3
"""Regenerate Foreword's AppIcon.appiconset from square source artwork.

Usage: scripts/make-app-icon.py <source-image> [--inset PX]

The source is full-bleed artwork (any square size, e.g. 2048x2048) whose
rounded-square background reaches the image edges. The script:

  1. crops `--inset` pixels off every side so anti-aliased edge pixels and
     any background outside the source's own rounded corners are dropped,
  2. masks the artwork with the macOS app icon shape,
  3. places it on the standard macOS icon grid: an 824px shape centred on a
     transparent 1024px canvas, with a soft drop shadow in the margin,
  4. writes every size the asset catalog lists (16pt-512pt @1x/@2x).

Needs Pillow and NumPy (`pip install pillow numpy`).
"""

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

CANVAS = 1024
SHAPE = 824
MARGIN = (CANVAS - SHAPE) // 2
# Shape and shadow measured from icons rendered by macOS 26 (IconServices,
# 1024px): a square whose corners are superellipse arcs reaching CORNER px
# along each edge, and a shadow offset/blurred/faded as below. Matches the
# system shape to within ~0.2px along the outline.
CORNER = 274
CORNER_EXPONENT = 2.7
SUPERSAMPLE = 4
SHADOW_OFFSET_Y = 8
SHADOW_BLUR = 14
SHADOW_OPACITY = 0.26

APPICONSET = Path(__file__).resolve().parent.parent / "Foreword/Foreword/Assets.xcassets/AppIcon.appiconset"
SIZES = {  # filename -> pixel size
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}


def icon_shape_mask(size: int) -> Image.Image:
    """Anti-aliased macOS icon shape filling a size x size box."""
    corner = CORNER * size / SHAPE
    big = size * SUPERSAMPLE
    u = (np.arange(big) + 0.5) / SUPERSAMPLE
    edge_distance = np.minimum(u, size - u)
    x, y = np.meshgrid(edge_distance, edge_distance)
    # Inside the corner square, normalised distance from the corner's arc centre.
    dx = np.clip((corner - x) / corner, 0.0, None)
    dy = np.clip((corner - y) / corner, 0.0, None)
    inside = (dx ** CORNER_EXPONENT + dy ** CORNER_EXPONENT) <= 1.0
    mask = Image.fromarray((inside * 255).astype(np.uint8), "L")
    return mask.resize((size, size), Image.Resampling.BOX)


def build_master(source: Image.Image, inset: int) -> Image.Image:
    if source.width != source.height:
        sys.exit(f"source must be square, got {source.width}x{source.height}")
    artwork = source.convert("RGB").crop((inset, inset, source.width - inset, source.height - inset))
    artwork = artwork.resize((SHAPE, SHAPE), Image.Resampling.LANCZOS)
    mask = icon_shape_mask(SHAPE)

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))

    shadow_alpha = Image.new("L", (CANVAS, CANVAS), 0)
    shadow_alpha.paste(mask, (MARGIN, MARGIN + SHADOW_OFFSET_Y))
    shadow_alpha = shadow_alpha.filter(ImageFilter.GaussianBlur(SHADOW_BLUR))
    shadow_alpha = shadow_alpha.point(lambda v: round(v * SHADOW_OPACITY))
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 255))
    shadow.putalpha(shadow_alpha)
    canvas.alpha_composite(shadow)

    shape = artwork.convert("RGBA")
    shape.putalpha(mask)
    canvas.alpha_composite(shape, (MARGIN, MARGIN))
    return canvas


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", type=Path)
    parser.add_argument("--inset", type=int, default=12,
                        help="pixels to crop from each side of the source before masking (default 12)")
    args = parser.parse_args()

    master = build_master(Image.open(args.source), args.inset)
    for name, px in SIZES.items():
        image = master if px == CANVAS else master.resize((px, px), Image.Resampling.LANCZOS)
        image.save(APPICONSET / name, optimize=True)
        print(f"wrote {name} ({px}x{px})")


if __name__ == "__main__":
    main()
