#!/bin/sh
# Compile QC/SMD into MDL/VVD/VTX/PHY with PulseModel, a native Linux studiomdl replacement.
#
# -vtxformat 1 is required: Insurgency is a CS:GO-branch build, and format 1 is the CS:GO/SFM/ASW
# .vtx strip layout. Format 0 is the older TF2/HL2 one and would produce a model the engine
# misreads. The compiler prints which layout it used - check it if geometry looks wrong.
#
# The template pre-pass has already rewritten $cdmaterials to the hashed material directory, so the compiled
# MDL references it directly, with no byte patching of the MDL string table.
set -eu
SRC="$1"; OUT="$2"
MDLCOMPILER="${MDLCOMPILER:-mdlcompiler}"
: "${GAME_DIR:?GAME_DIR is not set - the compiler needs a -game directory with gameinfo.txt}"

mkdir -p "$OUT" "$GAME_DIR/models"
found=0
for qc in "$SRC"/*.qc; do
  [ -e "$qc" ] || continue
  # *_for_definebones.qc only exists to print a skeleton; it is not a model.
  case "$(basename "$qc")" in *_for_definebones.qc) continue ;; esac
  echo "   mdlcompiler $(basename "$qc")"
  # Run with the source directory as CWD and a relative script path: compilers in this family
  # chdir to the script's directory, which breaks relative source lookups given an absolute path.
  ( cd "$SRC" && "$MDLCOMPILER" "$(basename "$qc")" -game "$GAME_DIR" -vtxformat 1 )
  found=$((found + 1))
done
[ "$found" -gt 0 ] || { echo "compile_models: no .qc found in $SRC" >&2; exit 1; }

# Output lands in <game>/models/<$modelname>, which the QCs set to twp/.
for f in "$GAME_DIR"/models/twp/*; do
  [ -e "$f" ] || continue
  cp "$f" "$OUT/"
done
[ -n "$(find "$OUT" -type f -print -quit)" ] || { echo "compile_models: nothing produced" >&2; exit 1; }
echo "   compiled: $(find "$OUT" -type f | wc -l) file(s)"
