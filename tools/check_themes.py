#!/usr/bin/env python3
"""Contrast and distinctness checker for themes.json (Marquee iOS, Lucent colour roles).

    python3 check_themes.py [themes.json]

Alpha colours are composited before any ratio is taken: ink and ink2 over the
sheet (itself composited over the canvas) or straight over the canvas, accent
over the canvas, accentInk over the composited accent.  Ratios use WCAG 2.x
relative luminance.  Exit status is 1 when any required rule fails.

Required (a failure fails the run)
  schema    exactly the 20 Lucent roles; #RRGGBB or #RRGGBBAA; opaque canvas;
            mode dark|light; unique id and name
  coverage  >= 20 dark and >= 20 light themes; rose-pine, rose-pine-moon and
            rose-pine-dawn present; default is rose-pine
  text      ink and ink2 vs canvas and vs sheet          >= 4.5
            ink2 on the sheet at full opacity (panels over video)   >= 4.5
            ink on the hero fade (canvas at .85 over pure black or white art) >= 4.5
  accent    accentInk vs accent                           >= 4.5
  non-text  accent vs canvas, focus vs canvas             >= 3.0
            slider track (ink at .60 over the surface) vs canvas, vs sheet   >= 3.0
  distinct  no two themes of one mode share a lightness/chroma recipe: for each
            pair at least one of canvas L, canvas chroma, surface step, accent L,
            accent chroma, ink L, ink chroma differs by more than its tolerance
            (TOL below, OKLab units).  Hue is ignored, so a hue-rotated copy of
            another theme is rejected

Advisory (printed as notes, never fail the run)
  semantic roles vs canvas >= 3.0, focusInk vs focus >= 4.5, ink and ink2 on
  glass / glassRaised >= 4.5, ink on the .97 confirmation backdrop >= 4.5,
  ink2 on the sheet over a pure black or pure white video frame (translucent) >= 4.5,
  accentInk on the danger fill >= 4.5 (a bold label may use the 3:1 large-text rule),
  accent as small text >= 4.5, accent not confusable with a semantic tone.
"""
import json
import math
import re
import sys
from pathlib import Path

ROLES = ["canvas", "sheet", "scrim", "glass", "glassRaised", "edge", "edgeRaised",
         "ink", "ink2", "ink3", "focus", "focusInk", "trackOff", "accent", "accentInk",
         "positive", "warning", "danger", "info", "live"]
SEMANTIC = ["positive", "warning", "danger", "info", "live"]
HEX = re.compile(r"^#([0-9A-Fa-f]{6})([0-9A-Fa-f]{2})?$")

MIN_PER_MODE = 20
REQUIRED_IDS = ("rose-pine", "rose-pine-moon", "rose-pine-dawn")
DEFAULT_ID = "rose-pine"
TEXT, NON_TEXT = 4.5, 3.0
CONFIRM_SCRIM_ALPHA = 0.97
HERO_FADE_ALPHA = 0.85       # hero art fades to the canvas; the title sits on this much canvas
TRACK_INK_MIX = 0.60        # Lucent material.trackInkMix: the readable slider and scrubber track
MIN_TONE_GAP = 0.07         # OKLab distance between accent and a semantic tone

# Two themes of one mode are the same recipe when every feature differs by less than its
# tolerance; hue is deliberately not a feature.  The tolerances are design choices, not a standard.
TOL = {"Lc": 0.03, "Cc": 0.02, "lift": 0.02, "La": 0.06, "Ca": 0.05, "Li": 0.03, "Ci": 0.015}
MIN_GAP = 1.0               # largest per-feature difference, in tolerances, between two themes


# ---------- colour maths ----------

def parse(s):
    m = HEX.match(s)
    if not m:
        raise ValueError(f"bad colour {s!r}")
    h, a = m.group(1), m.group(2)
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return r, g, b, (int(a, 16) / 255 if a else 1.0)


def comp(fg, under, alpha=None):
    """Composite fg (r, g, b, a) over an opaque rgb triple."""
    r, g, b, a = fg
    a = a if alpha is None else alpha
    return tuple(c * a + u * (1 - a) for c, u in zip((r, g, b), under))


def lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def lum(rgb):
    r, g, b = (lin(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def ratio(a, b):
    la, lb = lum(a), lum(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def oklab(rgb):
    r, g, b = (lin(c) for c in rgb)
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l, m, s = (math.copysign(abs(x) ** (1 / 3), x) for x in (l, m, s))
    return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)


def oklch(rgb):
    L, a, b = oklab(rgb)
    return L, math.hypot(a, b), math.degrees(math.atan2(b, a)) % 360


def delta_e(x, y):
    return math.dist(oklab(x), oklab(y))


# ---------- per-theme analysis ----------

def analyse(theme):
    c = {k: parse(v) for k, v in theme["colors"].items()}
    canvas = c["canvas"][:3]
    sheet = comp(c["sheet"], canvas)
    ink_c, ink2_c = comp(c["ink"], canvas), comp(c["ink2"], canvas)
    ink_s, ink2_s = comp(c["ink"], sheet), comp(c["ink2"], sheet)
    accent = comp(c["accent"], canvas)
    focus = comp(c["focus"], canvas)
    glass, raised = comp(c["glass"], canvas), comp(c["glassRaised"], canvas)
    confirm = comp(c["scrim"], canvas, CONFIRM_SCRIM_ALPHA)

    req = {
        "ink/canvas": ratio(ink_c, canvas), "ink/sheet": ratio(ink_s, sheet),
        "ink2/canvas": ratio(ink2_c, canvas), "ink2/sheet": ratio(ink2_s, sheet),
        "accentInk/accent": ratio(comp(c["accentInk"], accent), accent),
        "accent/canvas": ratio(accent, canvas), "focus/canvas": ratio(focus, canvas),
        "track/canvas": ratio(comp(c["ink"], canvas, TRACK_INK_MIX), canvas),
        "track/sheet": ratio(comp(c["ink"], sheet, TRACK_INK_MIX), sheet),
        "ink2/panel": ratio(comp(c["ink2"], c["sheet"][:3]), c["sheet"][:3]),
        "ink/hero": min(ratio(comp(c["ink"], u), u)
                        for u in (comp(c["canvas"], art, HERO_FADE_ALPHA)
                                  for art in ((0.0, 0.0, 0.0), (1.0, 1.0, 1.0)))),
    }
    need = {k: (TEXT if k.split("/")[0] in ("ink", "ink2", "accentInk") else NON_TEXT) for k in req}

    notes = []
    for role in SEMANTIC:
        r = ratio(comp(c[role], canvas), canvas)
        if r < NON_TEXT:
            notes.append(f"{role}/canvas {r:.2f}")
    r = ratio(comp(c["focusInk"], focus), focus)
    if r < TEXT:
        notes.append(f"focusInk/focus {r:.2f}")
    for name, surf in (("glass", glass), ("glassRaised", raised)):
        for ink in ("ink", "ink2"):
            r = ratio(comp(c[ink], surf), surf)
            if r < TEXT:
                notes.append(f"{ink}/{name} {r:.2f}")
    r = ratio(comp(c["ink"], confirm), confirm)
    if r < TEXT:
        notes.append(f"ink/confirm-backdrop {r:.2f}")
    for name, bg in (("black", (0.0, 0.0, 0.0)), ("white", (1.0, 1.0, 1.0))):
        panel = comp(c["sheet"], bg)
        r = ratio(comp(c["ink2"], panel), panel)
        if r < TEXT:
            notes.append(f"ink2/sheet-over-{name}-video {r:.2f}")
    r = req["accent/canvas"]
    if r < TEXT:
        notes.append(f"accent as text {r:.2f}")
    danger_fill = comp(c["danger"], canvas)
    r = ratio(comp(c["accentInk"], danger_fill), danger_fill)
    if r < TEXT:
        notes.append(f"accentInk/danger-fill {r:.2f} (label set bold)")
    for role in ("positive", "warning", "danger", "info", "live"):
        d = delta_e(accent, comp(c[role], canvas))
        if d < MIN_TONE_GAP:
            notes.append(f"accent~{role} d={d:.2f}")

    Lc, Cc, _ = oklch(canvas)
    Ls, _, _ = oklch(sheet)
    La, Ca, ha = oklch(accent)
    Li, Ci, _ = oklch(ink_c)
    structure = {"Lc": Lc, "Cc": Cc, "lift": Ls - Lc, "La": La, "Ca": Ca, "Li": Li, "Ci": Ci}
    return {"req": req, "need": need, "notes": notes, "structure": structure,
            "canvas_h": oklch(canvas)[2], "accent_h": ha}


def recipe_gap(a, b):
    """Largest per-feature difference in units of its tolerance; below 1 means the same recipe."""
    return max(abs(a[k] - b[k]) / TOL[k] for k in TOL)


# ---------- run ----------

def schema_errors(data):
    errs = []
    themes = data.get("themes")
    if not isinstance(themes, list):
        return ["`themes` must be a list"]
    seen_id, seen_name = set(), set()
    for t in themes:
        tid = t.get("id", "?")
        if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", str(tid)):
            errs.append(f"{tid}: id must be kebab-case")
        if tid in seen_id:
            errs.append(f"{tid}: duplicate id")
        seen_id.add(tid)
        name = t.get("name")
        if not name or name in seen_name:
            errs.append(f"{tid}: missing or duplicate name")
        seen_name.add(name)
        if t.get("mode") not in ("dark", "light"):
            errs.append(f"{tid}: mode must be dark|light")
        colors = t.get("colors", {})
        if sorted(colors) != sorted(ROLES):
            missing, extra = set(ROLES) - set(colors), set(colors) - set(ROLES)
            errs.append(f"{tid}: roles differ (missing {sorted(missing)}, extra {sorted(extra)})")
            continue
        for role, v in colors.items():
            if not HEX.match(str(v)):
                errs.append(f"{tid}.{role}: bad colour {v!r}")
        if HEX.match(str(colors["canvas"])) and parse(colors["canvas"])[3] != 1.0:
            errs.append(f"{tid}.canvas must be opaque")
    return errs


def main():
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).with_name("themes.json")
    data = json.loads(path.read_text())
    errors = schema_errors(data)
    themes = data["themes"]
    by_mode = {m: [t for t in themes if t.get("mode") == m] for m in ("dark", "light")}
    for m, ts in by_mode.items():
        if len(ts) < MIN_PER_MODE:
            errors.append(f"only {len(ts)} {m} themes, need {MIN_PER_MODE}")
    for tid in REQUIRED_IDS:
        if tid not in {t["id"] for t in themes}:
            errors.append(f"missing {tid}")
    if data.get("default") != DEFAULT_ID:
        errors.append(f"default must be {DEFAULT_ID}, got {data.get('default')!r}")
    if errors:
        print("SCHEMA / COVERAGE ERRORS")
        for e in errors:
            print("  -", e)
        print("RESULT: FAIL")
        return 1

    rows, req_fail, note_total, themes_with_notes = [], 0, 0, 0
    info = {}
    keys = ["ink/canvas", "ink/sheet", "ink2/canvas", "ink2/sheet", "accentInk/accent", "accent/canvas", "focus/canvas", "ink2/panel", "ink/hero", "track/canvas", "track/sheet"]
    print(f"{'id':<17}{'mode':<6}" + "".join(f"{k.replace('canvas', 'cv').replace('sheet', 'sh').replace('accentInk', 'aInk').replace('accent', 'acc'):>12}" for k in keys) + "  req  notes")
    for mode in ("dark", "light"):
        for t in by_mode[mode]:
            a = analyse(t)
            info[t["id"]] = a
            bad = [k for k in keys if a["req"][k] < a["need"][k]]
            req_fail += len(bad)
            note_total += len(a["notes"])
            themes_with_notes += 1 if a["notes"] else 0
            cells = "".join(f"{a['req'][k]:>12.2f}" for k in keys)
            print(f"{t['id']:<17}{mode:<6}{cells}  {'ok ' if not bad else 'FAIL'}  {len(a['notes'])}")
            if bad:
                print("      FAILED:", ", ".join(f"{k} {a['req'][k]:.2f} < {a['need'][k]}" for k in bad))

    print("\nADVISORY NOTES (do not fail the run)")
    for t in themes:
        n = info[t["id"]]["notes"]
        if n:
            print(f"  {t['id']:<17}", "; ".join(n))

    print(f"\nDISTINCTNESS (hue ignored; every pair must differ by >= {MIN_GAP:g} tolerance in at "
          "least one of canvas L, canvas chroma, surface step, accent L, accent chroma, ink L, ink chroma)")
    spread_fail = 0
    for mode in ("dark", "light"):
        ts = by_mode[mode]
        pairs = sorted((recipe_gap(info[a["id"]]["structure"], info[b["id"]]["structure"]), a["id"], b["id"])
                       for i, a in enumerate(ts) for b in ts[i + 1:])
        close = [p for p in pairs if p[0] < MIN_GAP]
        spread_fail += len(close)
        print(f"  {mode}: closest pairs " + ", ".join(f"{x}~{y} {d:.2f}" for d, x, y in pairs[:3]))
        for d, x, y in close:
            print(f"    SAME RECIPE {x} ~ {y} {d:.2f}")
        buckets_c = len({int(info[t['id']]['canvas_h'] // 30) for t in ts if info[t['id']]['structure']['Cc'] > 0.012})
        buckets_a = len({int(info[t['id']]['accent_h'] // 30) for t in ts if info[t['id']]['structure']['Ca'] > 0.03})
        print(f"  {mode}: canvas hue buckets used {buckets_c}/12 (tinted canvases), accent hue buckets used {buckets_a}/12")

    ok = req_fail == 0 and spread_fail == 0
    print("\nSUMMARY")
    for mode in ("dark", "light"):
        ts = by_mode[mode]
        passing = sum(1 for t in ts if all(info[t["id"]]["req"][k] >= info[t["id"]]["need"][k] for k in keys))
        print(f"  {mode:<5}: {len(ts)} themes, {passing} pass all required contrast rules")
    print(f"  required contrast failures: {req_fail}")
    print(f"  distinctness violations:    {spread_fail}")
    print(f"  advisory notes:             {note_total} across {themes_with_notes} themes")
    print(f"  default: {data['default']}")
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
