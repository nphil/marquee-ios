#!/usr/bin/env python3
"""Builds the three AppIcon variants from the Marquee TV app's logo master.

The master is the TV app's full-bleed logo: a flat dark field with the 3D "M" glyph.
The glyph's alpha is recovered from its distance to that field colour, then it is set
on each variant's own background:

  Light   the TV app's own field, full bleed, opaque (the "Any" appearance)
  Dark    the same glyph on a deeper near-black field, opaque
  Tinted  luminance-only glyph on transparent; iOS applies the tint and background

Usage: python3 tools/make_app_icon.py   (needs Pillow)
"""
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "Design/AppIcon/marquee-tv-logo.png"
OUT = ROOT / "Resources/Assets.xcassets/AppIcon.appiconset"
SIZE = 1024

FIELD = np.array([25, 22, 35], dtype=np.float32)  # measured flat field of the master
DARK_FIELD = np.array([11, 9, 17], dtype=np.float32)


def glyph_alpha(rgb: np.ndarray) -> np.ndarray:
    # Full coverage at 60 levels from the field, none at 8: the glyph's darkest facets sit
    # well above 60 and the master's compression noise below 8.
    dist = np.sqrt(((rgb - FIELD) ** 2).sum(axis=2))
    return np.clip((dist - 8) / 52, 0, 1)


def main() -> None:
    rgb = np.asarray(Image.open(SRC).convert("RGB"), dtype=np.float32)
    a = glyph_alpha(rgb)[..., None]
    # Un-premultiply the glyph against the field so edges carry no halo of the old background.
    safe = np.maximum(a, 1e-3)
    glyph = np.clip((rgb - (1 - a) * FIELD) / safe, 0, 255)

    # Resample glyph (premultiplied) and alpha as float planes, then recompose at 1024.
    planes = np.concatenate([glyph * a, a * 255], axis=2)
    small = np.stack(
        [np.asarray(Image.fromarray(planes[..., i].astype(np.float32), mode="F").resize((SIZE, SIZE), Image.LANCZOS))
         for i in range(4)],
        axis=2,
    )
    sa = np.clip(small[..., 3:4] / 255, 0, 1)
    sprem = np.clip(small[..., :3], 0, 255)

    def on(field: np.ndarray) -> Image.Image:
        out = sprem + (1 - sa) * field
        return Image.fromarray(np.clip(out + 0.5, 0, 255).astype(np.uint8), "RGB")

    on(FIELD).save(OUT / "AppIcon-Light.png", optimize=True)
    on(DARK_FIELD).save(OUT / "AppIcon-Dark.png", optimize=True)

    # Tinted: Rec. 709 luminance of the un-premultiplied glyph, stretched so the brightest
    # facet reaches white and the darkest keeps some body once iOS multiplies in the tint.
    straight = np.where(sa > 1e-3, sprem / np.maximum(sa, 1e-3), 0)
    lum = straight @ np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)
    top = np.percentile(lum[sa[..., 0] > 0.99], 99.5)
    grey = np.clip(lum / top, 0, 1) ** 0.85 * 255
    tinted = np.dstack([grey, grey, grey, sa[..., 0] * 255])
    Image.fromarray((tinted + 0.5).astype(np.uint8), "RGBA").save(OUT / "AppIcon-Tinted.png", optimize=True)

    # The Feather feed reads the light icon from the repo.
    on(FIELD).save(ROOT / "Resources/AppIcon-1024.png", optimize=True)


if __name__ == "__main__":
    main()
