#!/bin/sh
# Build the fast-download content tree: everything a client must resolve, laid out game-relative,
# under content-hashed directory names. See fastdl/README.md for why.
#
# ORDER MATTERS. Each group is hashed only after everything it references is resolved, so the hashes
# chain bottom-up: textures, the material naming them, the model naming the material, the theater
# naming the model.

set -eu

SRC="${SRC:-/src}"                 # fastdl/src
THEATERS="${THEATERS:-/theaters}"  # server config .../scripts/theaters
STUBS="${STUBS:-/stubs}"           # fastdl/map_asset_stubs/materials
OUT="${OUT:-/fastdl}"
WORK="${WORK:-/work}"
TOOLS="${TOOLS:-$(dirname "$0")}"
MODEL_COMPILE="${MODEL_COMPILE:-1}"

TOOL="${TOOL:-fastdl-tools}"
say() { printf '\n== %s\n' "$1"; }

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"

# ---------------------------------------------------------------- 1. textures
say "textures"
# Driven by what the materials and models actually reference, NOT by whatever the directory happens
# to contain - a scratch or comparison file left in src/textures must not become payload. Positive
# declaration, so it also catches the inverse mistake: a reference with no source behind it.
mkdir -p "$WORK/tex-src"
TEXREFS=$(grep -rhoE '@@MATPATH\(tex,[^)]+\)@@' "$SRC/materials" "$SRC/models" 2>/dev/null \
          | sed -E 's/.*,[[:space:]]*([^)]+)\)@@/\1/' | sort -u)
# @@DIR(tex)@@ / @@MATDIR(tex)@@ name the directory rather than a file, so filtering by name would be
# wrong; ship everything in that case.
if grep -rqE '@@(DIR|MATDIR)\(tex\)@@' "$SRC/materials" "$SRC/models" 2>/dev/null; then
  echo "   directory referenced wholesale - shipping every source"
  cp -a "$SRC"/textures/. "$WORK/tex-src/"
else
  [ -n "$TEXREFS" ] || { echo "No texture is referenced by any material" >&2; exit 1; }
  for stem in $TEXREFS; do
    if [ -e "$SRC/textures/$stem.png" ]; then
      cp -a "$SRC/textures/$stem.png" "$WORK/tex-src/"
      [ -e "$SRC/textures/$stem.png.txt" ] && cp -a "$SRC/textures/$stem.png.txt" "$WORK/tex-src/"
    elif [ -e "$SRC/textures/$stem.vtf" ]; then
      cp -a "$SRC/textures/$stem.vtf" "$WORK/tex-src/"
    else
      echo "Referenced texture '$stem' has no .png or .vtf in $SRC/textures" >&2
      exit 1
    fi
  done
  # Anything present but unreferenced is dead weight; say so rather than ship it silently.
  for f in "$SRC"/textures/*.png "$SRC"/textures/*.vtf; do
    [ -e "$f" ] || continue
    b=$(basename "$f"); stem=${b%.*}
    [ -e "$WORK/tex-src/$b" ] || echo "   skipping unreferenced $b"
  done
fi
"$TOOL" vtfc "$WORK/tex-src" "$WORK/tex"
TEXNAME=$("$TOOL" hashdir twp_tex "$WORK/tex")
TEXDIR="materials/models/$TEXNAME"
mkdir -p "$OUT/$TEXDIR"
cp -a "$WORK/tex/." "$OUT/$TEXDIR/"
echo "   -> $TEXDIR"

# ---------------------------------------------------------------- 2. materials
say "materials"
"$TOOL" template --set "tex=$TEXDIR" "$SRC/materials" "$WORK/mat"
MATNAME=$("$TOOL" hashdir twp "$WORK/mat")
MATDIR="materials/models/$MATNAME"
mkdir -p "$OUT/$MATDIR"
cp -a "$WORK/mat/." "$OUT/$MATDIR/"
echo "   -> $MATDIR"

# ---------------------------------------------------------------- 3. models
# COMPILED TWICE, ON PURPOSE. The published directory name is a hash of the compiled bytes, but the
# QC's $modelname has to contain that same name before the compile, because the engine derives the
# .vvd/.vtx/.phy filenames from $modelname rather than from where it found the .mdl - so a model
# published under a hashed directory with an unhashed $modelname reads its vertices from the fixed
# path instead, which is write-once on every client and goes stale forever. See the MDLNAME note in
# tools/template.go for the instruction-level detail and the symptom.
#
# Pass 1 compiles under a fixed placeholder name purely to get a hash of the content. Pass 2 puts
# that hash in $modelname and compiles what is actually shipped. The published bytes therefore do
# not hash to their own directory name - the name is the hash of pass 1 - but it is still a pure
# function of the sources and the compiler, which is all the name has to be. Pass 1 is what makes a
# compiler change move the name too, which hashing the templated SOURCES would not.
MDLDIR=""
if [ "$MODEL_COMPILE" = "1" ] && [ -d "$SRC/models" ] && [ -n "$(find "$SRC/models" -name '*.qc' -print -quit 2>/dev/null)" ]; then
  say "models"
  MDLPROBE=twp_probe
  "$TOOL" template --lowercase-names --set "mat=$MATDIR" --set "mdl=models/$MDLPROBE" \
          "$SRC/models" "$WORK/mdl_src_probe"
  sh "$TOOLS/compile_models.sh" "$WORK/mdl_src_probe" "$WORK/mdl_probe" "$MDLPROBE"
  MDLNAME=$("$TOOL" hashdir twp "$WORK/mdl_probe")
  MDLDIR="models/$MDLNAME"

  echo "   recompiling with \$modelname = $MDLNAME"
  "$TOOL" template --lowercase-names --set "mat=$MATDIR" --set "mdl=$MDLDIR" \
          "$SRC/models" "$WORK/mdl_src"
  sh "$TOOLS/compile_models.sh" "$WORK/mdl_src" "$WORK/mdl" "$MDLNAME"

  # The whole point of the two passes: if this ever fails, the models are back to loading their
  # vertices from a fixed path and the hashing is silently doing nothing.
  for m in "$WORK/mdl"/*.mdl; do
    [ -e "$m" ] || continue
    if ! tr -d '\000' < "$m" | head -c 256 | grep -q "$MDLNAME"; then
      echo "\$modelname in $(basename "$m") does not carry $MDLNAME - vertex files would load from a fixed path" >&2
      exit 1
    fi
  done

  mkdir -p "$OUT/$MDLDIR"
  cp -a "$WORK/mdl/." "$OUT/$MDLDIR/"
  echo "   -> $MDLDIR"
else
  say "models (SKIPPED - MODEL_COMPILE=$MODEL_COMPILE or no .qc sources)"
  echo "   Theaters will keep whatever model path they already name."
fi

# ---------------------------------------------------------------- 4. localisation
# Named by the theater, exactly like the models are - see the "localize" key in the theater's
# core/precache block. That is the ONLY way a mod's strings reach the client: CLocalize::AddFile
# loads localisation by exact filename (substituting "english" for %language%) and never scans a
# directory unless the process was started with -all_languages, so a file the game has not been
# told about is inert wherever it sits. Proven both ways on the test client: the same tokens at
# three unreferenced names under resource/ and resource/ui/ did nothing, while a copy merged into
# resource/insurgency_english.txt loaded. TUG reaches its own 427 strings through this key.
#
# Hashed as a DIRECTORY rather than by filename, so the theater can name a stable basename. This
# has to resolve before the theaters, because the theater is what references it.
#
# Copied byte-for-byte, never templated: Source localisation files are UTF-16LE.
LOCDIR=""
if [ -d "$SRC/localization" ] && [ -n "$(find "$SRC/localization" -name '*.txt' -print -quit 2>/dev/null)" ]; then
  say "localisation"
  LOCNAME=$("$TOOL" hashdir twp_loc "$SRC/localization")
  LOCDIR="resource/ui/$LOCNAME"
  mkdir -p "$OUT/$LOCDIR"
  cp -a "$SRC"/localization/. "$OUT/$LOCDIR/"
  echo "   -> $LOCDIR"
fi

# ---------------------------------------------------------------- 5. theaters
say "theaters"
mkdir -p "$OUT/scripts/theaters"
if [ -n "$(find "$THEATERS" -name '*.theater' -print -quit 2>/dev/null)" ]; then
  mkdir -p "$WORK/theaters_src"
  cp "$THEATERS"/*.theater "$WORK/theaters_src/"
  # Every group the theater can name is passed in. A theater that references a group which was
  # skipped this build fails on the unresolved placeholder rather than shipping it, which is what
  # keeps a half-built tree from reaching a client.
  set -- template
  [ -n "$MDLDIR" ] && set -- "$@" --set "mdl=$MDLDIR"
  [ -n "$LOCDIR" ] && set -- "$@" --set "loc=$LOCDIR"
  mkdir -p "$WORK/theaters"
  if [ "$#" -gt 1 ]; then
    "$TOOL" "$@" "$WORK/theaters_src" "$WORK/theaters"
  else
    cp "$WORK/theaters_src"/*.theater "$WORK/theaters/"
  fi
  cp "$WORK/theaters"/*.theater "$OUT/scripts/theaters/"

  # Each theater also gets a copy whose name carries a hash of the whole set, so a changed theater
  # is a filename no client has ever had.  The per-gamemode variants #base the base theater by
  # name, so the copies have to point at the copy rather than back at the original.
  cd "$OUT/scripts/theaters"
  base=$(ls *.theater | sed 's/\.theater$//' | awk '{ print length, $0 }' | LC_ALL=C sort -n | head -1 | cut -d' ' -f2-)
  thash=$(LC_ALL=C cat *.theater | sha256sum | cut -c1-12)
  for f in *.theater; do
    stem=${f%.theater}
    case "$stem" in
      "$base") suffix="" ;;
      "$base"_*) suffix="_${stem#${base}_}" ;;
      *) echo "Theater $f does not share base name $base" >&2; exit 1 ;;
    esac
    cp "$f" "${base}_${thash}${suffix}.theater"
  done
  sed -i "s|\"${base}\.theater\"|\"${base}_${thash}.theater\"|g" ${base}_${thash}*.theater
  printf '%s' "${base}_${thash}" > "$WORK/theater-name"
  echo "   -> ${base}_${thash}"
  cd - > /dev/null
fi

# ---------------------------------------------------------------- 6. map stubs
# Deliberately not hashed: their paths are hardcoded in each map's BSP and cannot move.
if [ -d "$STUBS" ]; then
  say "map asset stubs"
  mkdir -p "$OUT/materials"
  cp -a "$STUBS/." "$OUT/materials/"
  echo "   -> materials/ (unhashed, paths fixed by BSP)"
fi



# ---------------------------------------------------------------- 7. vgui icons
# Deliberately not hashed. The buy-menu icon is looked up as materials/vgui/inventory/<weapon>.vmt
# with no way to override the path from the theater, so hashing it would mean renaming the weapon -
# which is also its localisation token and what LoadoutSaver stores, so saved loadouts would break on
# every texture edit. A stale icon is a far smaller problem.
if [ -d "$SRC/vgui" ]; then
  say "vgui icons"
  mkdir -p "$WORK/vgui-src" "$WORK/vgui" "$OUT/materials/vgui/inventory"
  # Driven by the .vmt files, NOT by whatever the directory happens to contain: a scratch or
  # comparison file left in src/vgui must not become 700KB of payload at a path nothing references.
  # Each icon ships its .vmt plus one texture, preferring a rendered PNG over a hand-authored one.
  for vmt in "$SRC"/vgui/*.vmt; do
    [ -e "$vmt" ] || continue
    stem=$(basename "$vmt" .vmt)
    cp -a "$vmt" "$WORK/vgui/"
    [ -e "$SRC/vgui/$stem.png.txt" ] && cp -a "$SRC/vgui/$stem.png.txt" "$WORK/vgui-src/"
    if [ -n "${ICONS:-}" ] && [ -e "$ICONS/$stem.png" ]; then
      cp -a "$ICONS/$stem.png" "$WORK/vgui-src/"
      echo "   using rendered $stem.png"
    elif [ -e "$SRC/vgui/$stem.png" ]; then
      cp -a "$SRC/vgui/$stem.png" "$WORK/vgui-src/"
    elif [ -e "$SRC/vgui/$stem.vtf" ]; then
      cp -a "$SRC/vgui/$stem.vtf" "$WORK/vgui-src/"
    else
      # Not every icon owns a texture. The ammo-upgrade icons are a one-line VMT pointing at a
      # SHARED kit_* texture the base game already ships - which is how the stock ammo_ap_*.vmt and
      # ammo_hp_*.vmt icons work too - so there is nothing of ours to compile for them.
      #
      # Only warn when the VMT names a texture with its OWN stem, because that is the case where a
      # source file was expected and is genuinely missing.
      ref=$(sed -n 's/.*"\$basetexture"[[:space:]]*"\([^"]*\)".*/\1/p' "$vmt" | head -1)
      case "${ref##*/}" in
        "$stem") echo "   WARNING: $stem.vmt names its own texture but no source exists" >&2 ;;
        *)       echo "   $stem.vmt -> ${ref:-<no \$basetexture>} (shared texture, nothing to compile)" ;;
      esac
    fi
  done
  # Compiled here rather than in the textures group so the .vtf lands unhashed beside the .vmt that
  # names it. The pair must share a refreshability group: a hashed texture behind an unhashed VMT
  # would leave a stale client pointing at a path no longer served.
  if [ -n "$(find "$WORK/vgui-src" \( -name '*.png' -o -name '*.vtf' \) -print -quit 2>/dev/null)" ]; then
    "$TOOL" vtfc "$WORK/vgui-src" "$WORK/vgui"
  fi
  cp -a "$WORK/vgui/." "$OUT/materials/vgui/inventory/"
  echo "   -> materials/vgui/inventory/ (unhashed, path fixed by weapon name)"
fi

# ---------------------------------------------------------------- 8. packaging
# Both a plain and a .bz2 copy: the engine asks for "%s.bz2" first, and serving only one form means
# a 404 on whichever it tries first.
say "packaging"
find "$OUT" -type f ! -name '*.bz2' -exec bzip2 -k -9 {} \;
find "$OUT" -type d -exec chmod 755 {} \;
find "$OUT" -type f -exec chmod 644 {} \;

cd "$OUT"
find . -type f ! -name MANIFEST.txt ! -name '*.bz2' -print0 \
  | LC_ALL=C sort -z | xargs -0 sha256sum > MANIFEST.txt

# The contract with the game server, fetched over HTTP at every map change rather than baked into
# the server image - which is what decouples them.
#
#   files    - the downloadables string table. A client only fetches what the server advertises.
#   theater  - the hashed base name. mp_theater_override must match it exactly; the engine enforces
#              theater files by CRC.
find . -type f ! -name MANIFEST.txt ! -name downloadables.txt ! -name manifest.json ! -name '*.bz2' \
  | sed 's|^\./||' | LC_ALL=C sort > downloadables.txt
{
  printf '{\n  "theater": "%s",\n  "files": [\n' "$(cat "$WORK/theater-name" 2>/dev/null || true)"
  sed 's/.*/    "&",/' downloadables.txt | sed '$ s/,$//'
  printf '  ]\n}\n'
} > manifest.json
chmod 644 MANIFEST.txt downloadables.txt manifest.json

cd - > /dev/null

echo "   theater: $(cat "$WORK/theater-name" 2>/dev/null || echo '(none)')"
echo "   files:   $(wc -l < "$OUT/downloadables.txt")"
