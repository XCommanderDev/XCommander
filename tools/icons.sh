#!/bin/bash
# Generate every icon the app ships, from the one vector source.
#
#   tools/icons.sh            regenerate everything
#   tools/icons.sh --preview  also write comparison strips to /tmp for eyeballing
#
# The source of truth is Design/autographe-v1.svg. Nothing here is hand-edited artwork:
# the script renders Wassim's file, and the only transform it applies is the macOS icon
# grid, which is a platform requirement rather than a design decision. If the SVG changes,
# run this and commit what it writes.
#
# What it produces:
#   Sources/Companion/AutographeAppIcon.icon/Assets/pens.png     the app icon's one layer
#   Sources/Companion/Assets.xcassets/MenuBarMark.imageset/*.png the menu-bar template mark
#   Sources/Companion/AutographeAppIcon.icon/Assets/pens.png     the Icon Composer layer
#   Design/autographe-v1-macos-1024.png                          grid-correct master, reference
#   Design/AutographeForXcode.icns                               for the DMG volume icon
set -euo pipefail
cd "$(dirname "$0")/.."

command -v rsvg-convert >/dev/null || { echo "need rsvg-convert (brew install librsvg)"; exit 1; }
python3 -c "import PIL" 2>/dev/null || { echo "need Pillow (pip3 install Pillow)"; exit 1; }

SVG="Design/autographe-v1.svg"
MARKSET="Sources/Companion/Assets.xcassets/MenuBarMark.imageset"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The app icon is the Icon Composer document, so these ten PNGs are no longer an asset
# catalogue slot — actool would not even compile them. They exist only to build the .icns
# the DMG's volume icon needs, so they are rendered into the temp dir and not committed.
ICONSET="$WORK/AutographeForXcode.iconset"

# --- The macOS grid ------------------------------------------------------------------
#
# An iOS icon is full-bleed: artwork fills all 1024 and the system masks the corners. A
# macOS icon carries its own shape *and* its own margin — the tile is 824x824 inside a
# 1024 canvas, leaving ~100pt on every side. Get this wrong and nothing breaks; the icon
# just renders visibly larger than every icon beside it.
#
# The SVG's own tile is 896 wide inside its 1024 canvas (it already has 64pt of padding).
# So to land the tile on 824 we render the whole SVG at 1024 * 824/896 = 941.7 and centre
# that on a 1024 canvas: 41.1 + 58.9 = 100pt of padding, as required.
#
# This is a uniform scale. Nothing is redrawn, and the corner radius keeps the ratio the
# SVG chose (0.232 of the side, against Apple's 0.225) — 3% rounder, which is Wassim's
# design and not the grid's business.
GRID_SCALE="0.9198341"   # 824/896
MASTER=4096              # render big once, downsample; small sizes come out cleaner

echo "==> rendering the master at ${MASTER}px"
ART=$(python3 -c "print(round($MASTER * $GRID_SCALE))")
rsvg-convert -w "$ART" -h "$ART" -f png -o "$WORK/art.png" "$SVG"

python3 - "$WORK" "$MASTER" <<'PY'
import sys
from PIL import Image
work, master = sys.argv[1], int(sys.argv[2])
art = Image.open(work + "/art.png").convert("RGBA")
canvas = Image.new("RGBA", (master, master), (0, 0, 0, 0))
off = ((master - art.size[0]) // 2, (master - art.size[1]) // 2)
canvas.paste(art, off, art)
canvas.save(work + "/master.png")
PY

echo "==> flat icon: 10 slots, for the .icns only"
mkdir -p "$ICONSET"
python3 - "$WORK" "$ICONSET" <<'PY'
import sys
from PIL import Image
work, out = sys.argv[1], sys.argv[2]
master = Image.open(work + "/master.png")
# (point size, scale) -> pixels. macOS asks for five sizes at 1x and 2x.
for pt in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        px = pt * scale
        name = f"icon_{pt}x{pt}.png" if scale == 1 else f"icon_{pt}x{pt}@{scale}x.png"
        master.resize((px, px), Image.LANCZOS).save(f"{out}/{name}")
        print(f"    {name}  {px}x{px}")
PY

echo "==> grid-correct master, for reference"
python3 - "$WORK" <<'PY'
import sys
from PIL import Image
work = sys.argv[1]
Image.open(work + "/master.png").resize((1024, 1024), Image.LANCZOS) \
     .save("Design/autographe-v1-macos-1024.png")
PY

# --- The menu-bar mark ---------------------------------------------------------------
#
# The pens alone, with the tile hidden. This is what makes a *template* image possible:
# macOS discards a template's colours and uses its alpha as a mask, so the artwork's
# transparency has to be its shape. A filled tile's alpha is a rounded rectangle, which is
# why the whole app icon can never be a template — it renders as a blank square. The pens
# knocked out are a silhouette, and a silhouette is exactly what a template wants.
echo "==> menu-bar mark: pens only, knocked out"
python3 - "$SVG" "$WORK" <<'PY'
import sys
svg, work = sys.argv[1], sys.argv[2]
src = open(svg).read()
marker = '<g\n     id="app-background-blue"'
assert marker in src, "the background group moved; check the SVG's structure"
open(work + "/pens.svg", "w").write(
    src.replace(marker, '<g\n     style="display:none"\n     id="app-background-blue"', 1))
PY
rsvg-convert -w 2048 -h 2048 -f png -o "$WORK/pens.png" "$WORK/pens.svg"

mkdir -p "$MARKSET" Sources/Companion/AutographeAppIcon.icon/Assets
python3 - "$WORK" "$MARKSET" <<'PY'
import sys, json
from PIL import Image
work, out = sys.argv[1], sys.argv[2]
pens = Image.open(work + "/pens.png").convert("RGBA")
pens = pens.crop(pens.split()[3].getbbox())          # trim to the ink

# The Icon Composer layer keeps the full 1024 frame and its position within it, because
# Icon Composer places layers against the canvas, not against their own bounds.
full = Image.open(work + "/pens.png").convert("RGBA")
full.resize((1024, 1024), Image.LANCZOS).save(
    "Sources/Companion/AutographeAppIcon.icon/Assets/pens.png")

# The menu bar draws into an 18pt box. Fit the ink inside it, longest side first, so the
# mark is as large as the bar allows without touching its edges.
BOX = 18
for scale in (1, 2):
    side = BOX * scale
    w, h = pens.size
    f = side / max(w, h)
    ink = pens.resize((max(1, round(w * f)), max(1, round(h * f))), Image.LANCZOS)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(ink, ((side - ink.size[0]) // 2, (side - ink.size[1]) // 2), ink)
    name = "mark.png" if scale == 1 else f"mark@{scale}x.png"
    canvas.save(f"{out}/{name}")
    print(f"    {name}  {side}x{side}")

json.dump({
    "images": [
        {"idiom": "mac", "scale": "1x", "filename": "mark.png"},
        {"idiom": "mac", "scale": "2x", "filename": "mark@2x.png"},
    ],
    "info": {"author": "xcode", "version": 1},
    "properties": {"template-rendering-intent": "template"},
}, open(f"{out}/Contents.json", "w"), indent=2)
PY

# --- The .icns, for the DMG ----------------------------------------------------------
#
# Xcode compiles the asset catalogue into the bundle's icon by itself. This standalone
# .icns is for the things Xcode does not build: the DMG's volume icon, mostly, since the
# app ships outside the App Store.
echo "==> .icns"
iconutil -c icns "$ICONSET" -o Design/AutographeForXcode.icns
echo "    Design/AutographeForXcode.icns"

echo "done."
