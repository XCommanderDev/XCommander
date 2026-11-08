#!/bin/bash
# Generate every icon the app ships, from the artwork in Graphics/.
#
#   tools/icons.sh
#
# The sources of truth are the files in Graphics/, and nothing here is hand-edited artwork:
#
#   Graphics/XCommanderAppIconDefault.icon   the app icon, an Icon Composer document
#   Graphics/X-hat-black-on-white2.svg       the hat on its own, for the menu bar
#
# If either changes, run this and commit what it writes.
#
# What it produces:
#   Sources/Companion/XCommanderAppIcon.icon/                    the app icon, copied as is
#   Sources/Companion/Assets.xcassets/MenuBarMark.imageset/*.png the menu-bar template mark
#   Design/XCommander.icns                                       for the DMG volume icon
set -euo pipefail
cd "$(dirname "$0")/.."

command -v rsvg-convert >/dev/null || { echo "need rsvg-convert (brew install librsvg)"; exit 1; }
python3 -c "import PIL" 2>/dev/null || { echo "need Pillow (pip3 install Pillow)"; exit 1; }

ICON_SRC="Graphics/XCommanderAppIconDefault.icon"
HAT="Graphics/X-hat-black-on-white2.svg"
# project.yml, Package.swift and tools/xc.sh refer to the document by this name.
ICON_DST="Sources/Companion/XCommanderAppIcon.icon"
MARKSET="Sources/Companion/Assets.xcassets/MenuBarMark.imageset"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- The app icon --------------------------------------------------------------------
#
# Icon Composer's document is the design: background fill, layers, glass, shadow. macOS 26
# draws it with its own geometry, and actool derives every legacy size from it. So it is
# copied, never re-rendered — any processing here could only make it differ from what the
# designer saw in Icon Composer.
echo "==> app icon: $ICON_SRC"
rm -rf "$ICON_DST"
cp -R "$ICON_SRC" "$ICON_DST"

# --- The menu-bar mark ---------------------------------------------------------------
#
# A template image keeps only alpha. This SVG's alpha is the hat's outline, but the ⌘ on the
# crown is painted *on top* in a light gradient, so alpha alone would draw a solid hat with
# no ⌘. The silhouette lives in the darkness: ink is wherever the artwork is both opaque and
# dark. Multiplying alpha by inverted luminance turns the light details into holes, which is
# what the bar needs to show them in its own colour.
echo "==> menu-bar mark: the hat, light details knocked out"
rsvg-convert -w 2048 -h 2048 -f png -o "$WORK/hat.png" "$HAT"

python3 - "$WORK" "$MARKSET" <<'PY'
import sys, json
from PIL import Image, ImageChops, ImageDraw
work, out = sys.argv[1], sys.argv[2]
hat = Image.open(work + "/hat.png").convert("RGBA")
r, g, b, a = hat.split()
darkness = ImageChops.invert(Image.merge("RGB", (r, g, b)).convert("L"))
ink = ImageChops.multiply(a, darkness)
ink = ink.crop(ink.getbbox())                       # trim to the ink

# Fill the trim. The thin white line that follows the hat's edge is detail for the app icon
# at 1024; at 13pt it only thins the hat out, and the mark loses its weight next to solid
# system glyphs. The trim is one long hole, so the rule is: fill every hole wider than half
# the hat. The ⌘ and the crossbones are small holes in the middle and stay cut out.
iw, ih = ink.size
solid = ink.point(lambda v: 255 if v > 127 else 0)
outside = Image.new("L", (iw + 2, ih + 2), 0)
outside.paste(solid, (1, 1))
ImageDraw.floodfill(outside, (0, 0), 100)            # everything reachable from the edge
outside = outside.crop((1, 1, iw + 1, ih + 1)).point(lambda v: 255 if v == 100 else 0)
holes = ImageChops.subtract(ImageChops.invert(outside), solid)
px = holes.load()
for y in range(0, ih, 2):
    for x in range(0, iw, 2):
        if px[x, y] != 255:
            continue
        ImageDraw.floodfill(holes, (x, y), 77)          # one hole
        one = holes.point(lambda v: 255 if v == 77 else 0)
        left, _, right, _ = one.getbbox()
        if right - left > iw / 2:
            ink = ImageChops.lighter(ink, one)
        holes = holes.point(lambda v: 0 if v == 77 else v)
        px = holes.load()

# The hat is 2.3 times wider than tall. In the 18pt square most marks use it would be 8pt
# high. Measured against a real menu bar, the system's glyphs are 11-16pt tall, so the
# canvas is 31x18pt and the hat comes out about 13pt high. A variable-length status item
# takes the width as given.
W, H = 31, 18
for scale in (1, 2):
    w, h = ink.size
    f = W * scale / w
    mask = ink.resize((W * scale, max(1, round(h * f))), Image.LANCZOS)
    canvas = Image.new("RGBA", (W * scale, H * scale), (0, 0, 0, 0))
    black = Image.new("RGBA", mask.size, (0, 0, 0, 255))
    black.putalpha(mask)
    canvas.paste(black, (0, (H * scale - mask.size[1]) // 2), black)
    name = "mark.png" if scale == 1 else f"mark@{scale}x.png"
    canvas.save(f"{out}/{name}")
    print(f"    {name}  {W * scale}x{H * scale}")

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
# The DMG's volume icon is the one place outside the app bundle that wants an .icns. actool
# writes one when it compiles the document, from the same geometry the system uses, so it is
# taken from there instead of being rendered separately.
echo "==> .icns"
actool "$ICON_DST" --compile "$WORK" --platform macosx --minimum-deployment-target 14.0 \
  --app-icon XCommanderAppIcon --output-partial-info-plist "$WORK/partial.plist" \
  --output-format human-readable-text >/dev/null
mkdir -p Design
cp "$WORK/XCommanderAppIcon.icns" Design/XCommander.icns
echo "    Design/XCommander.icns"

echo "done."
