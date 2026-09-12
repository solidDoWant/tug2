#!/bin/sh
# Render every buy-menu icon described by a *.render.txt beside its .vmt.
#
# Each config names the SMD to render; the diffuse comes from the textures source dir. Output is a
# PNG that the vgui step then compiles to a VTF, so a texture edit reaches the icon automatically.
set -eu
SRC="${1:?usage: render_icons.sh <src-dir> <out-dir>}"
OUT="${2:?usage: render_icons.sh <src-dir> <out-dir>}"
BLENDER="${BLENDER:-blender}"
TOOLS="${TOOLS:-$(dirname "$0")}"

mkdir -p "$OUT"
found=0
for cfg in "$SRC"/vgui/*.render.txt; do
  [ -e "$cfg" ] || continue
  name=$(basename "$cfg" .render.txt)
  echo "   render $name"
  "$BLENDER" --background --factory-startup --python "$TOOLS/render_icon.py" -- \
    --config "$cfg" --models "$SRC/models" --textures "$SRC/textures" \
    --render "$SRC/render" \
    --out "$OUT/$name.png" \
    2>&1 | grep -E 'render_icon:|Error|error:|Traceback' || true
  test -s "$OUT/$name.png" || { echo "render_icons: $name.png was not written" >&2; exit 1; }
  found=$((found + 1))
done
[ "$found" -gt 0 ] || echo "render_icons: no *.render.txt found, nothing to do"
