#!/bin/sh
# Fetch one bucket of workshop items and lay them out the way the engine expects.
#
# Usage: fetch-items <out dir> <id>:<manifest> [<id>:<manifest> ...]
#
# The manifest is the version workshop.lock.json pinned. steamcmd has no way to ask for a specific
# one - it always fetches whatever is current - so this checks what arrived and fails if Steam has
# moved on. That is the whole point of the pin: without the check the build would quietly ship a
# version the lockfile and the generated .acf both disagree with, and the .acf is what tells the
# running server the item is already up to date, so nothing downstream would ever notice.
set -eu

OUT="${1:?usage: fetch-items <out dir> <id>:<manifest> [...]}"
shift
[ "$#" -gt 0 ] || { echo "fetch-items: no items given" >&2; exit 1; }

APPID=222880
ROOT="${HOME:-/root}/.local/share/Steam/steamapps/workshop"
CONTENT="${ROOT}/content/${APPID}"
ACF="${ROOT}/appworkshop_${APPID}.acf"
ATTEMPTS=3

# The manifest steamcmd recorded for an item, out of its own copy of the .acf.
installed_manifest() {
    [ -f "${ACF}" ] || return 0
    awk -v want="$1" '
        /^\t"[A-Za-z]/           { section = $0; gsub(/[^A-Za-z]/, "", section) }
        section != "WorkshopItemsInstalled" { next }
        /^\t\t"[0-9]+"$/         { id = $0; gsub(/[^0-9]/, "", id); next }
        /"manifest"/ && id == want { m = $0; gsub(/[^0-9]/, "", m); print m; exit }
    ' "${ACF}"
}

missing=""
for pin in "$@"; do
    missing="${missing} ${pin}"
done

attempt=1
while [ "${attempt}" -le "${ATTEMPTS}" ]; do
    # Everything in one steamcmd run: logging in is most of the cost, and a bucket is a handful of
    # items.
    args=""
    for pin in ${missing}; do
        args="${args} +workshop_download_item ${APPID} ${pin%%:*}"
    done
    echo "fetch-items: attempt ${attempt} for$(echo "${missing}" | tr -s ' ')" >&2
    # shellcheck disable=SC2086
    steamcmd +login anonymous ${args} +quit || echo "fetch-items: steamcmd exited non-zero" >&2

    still_missing=""
    for pin in ${missing}; do
        [ -d "${CONTENT}/${pin%%:*}" ] || still_missing="${still_missing} ${pin}"
    done
    missing="${still_missing}"
    [ -n "${missing}" ] || break
    attempt=$((attempt + 1))
done

if [ -n "${missing}" ]; then
    echo "fetch-items: gave up on:${missing}" >&2
    exit 1
fi

mkdir -p "${OUT}"
for pin in "$@"; do
    id="${pin%%:*}"
    want="${pin#*:}"
    got="$(installed_manifest "${id}")"
    if [ "${got}" != "${want}" ]; then
        echo "fetch-items: ${id} is manifest ${got:-unknown}, lockfile pinned ${want}." >&2
        echo "             Steam has a newer version - run 'make workshop-lock' to re-pin." >&2
        exit 1
    fi
    rm -rf "${OUT}/${id}"
    mv "${CONTENT}/${id}" "${OUT}/${id}"
done

echo "fetch-items: $# items ready in ${OUT}" >&2
