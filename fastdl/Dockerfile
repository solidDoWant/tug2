# Fast-download content image: everything a client must hold a byte-identical copy of, built from
# source and published under content-hashed paths.
#
# Its own project rather than a stage in the server Dockerfile because the two are decoupled - the
# server reads manifest.json over HTTP at every map change, so this can be republished alone.
#
# See fastdl/README.md for why paths carry a hash and how the hash chain works. Publish this image
# BEFORE the server that enforces it, and warm or purge any CDN in front of it first.

# ---------------------------------------------------------------------------- tools
# Texture compiler, content hashing and the templating pre-pass. Go, matching tools/server-runner:
# one static binary, no runtime dependencies in the builder.
FROM golang:1.26 AS tools

RUN --mount=type=bind,source=fastdl/tools,target=/src \
    go build -C /src -o /fastdl-tools

# ---------------------------------------------------------------------------- model compiler
# PulseModel (MIT) - a native Linux studiomdl replacement emitting MDL v49, which is what the
# Insurgency branch compiles. Chosen over Valve's studiomdl because that is Windows-only, needs Wine,
# needs a Steam account that owns the game, and may not be redistributed inside an image - Docker
# layers are immutable, so a later `rm` would not remove it.
#
# Pinned: this is beta software and its script vocabulary changes between versions.
#
# -vtxformat 1 is required. Insurgency is a CS:GO-branch build (datacache.so carries the build path
# .../csgo/rel_pc/src/datacache/mdlcache.cpp), and format 1 is the CS:GO/SFM/ASW .vtx strip layout;
# format 0 is the older TF2/HL2 one.
FROM debian:bookworm-slim AS model-compiler

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
      build-essential cmake git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ARG PULSEMODEL_REF=5bad75ff03d0174ed36e7b4ae357b5ca6d316f50

# Upstream develops on MSVC, which includes <cstddef> transitively where GCC does not, so the build
# fails on libs/minicollision/convexhull.cpp. Drop the patch once upstream builds clean on GCC.
COPY fastdl/patches /patches

RUN git clone --filter=blob:none https://github.com/ToppiOfficial/PulseModel.git /pm \
    && cd /pm && git checkout -q "${PULSEMODEL_REF}" \
    && for p in /patches/*.patch; do [ -e "$p" ] || continue; git apply -v "$p"; done \
    && cmake -S /pm -B /pm/build -DCMAKE_BUILD_TYPE=Release \
    && cmake --build /pm/build -j "$(nproc)" \
    && install -Dm755 /pm/build/PulseModel/mdlcompiler /out/mdlcompiler \
    && /out/mdlcompiler -dumpcommands > /dev/null && echo "mdlcompiler runs"

# ---------------------------------------------------------------------------- icon renderer
# Buy-menu icons, rendered from the model so they track the texture.
#
# The inventory slot is drawn by CInventoryWeaponSlot from a fixed
# materials/vgui/inventory/<weapon>.vmt, so unlike the WeaponPreview CModelPanel the game will not
# render the model there. Rendering at build time is what keeps a recoloured texture in step with its
# icon instead of needing a second hand edit.
#
# Cycles on CPU: EEVEE needs a GPU/GL context a build container does not have. This stage is cached
# on its inputs, so it only re-runs when the model, texture or framing config changes.
FROM debian:bookworm-slim AS icon-render

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
      blender \
    && rm -rf /var/lib/apt/lists/*

COPY fastdl/tools/render_icon.py fastdl/tools/render_icons.sh /tools/
COPY fastdl/src /src
RUN TOOLS=/tools sh /tools/render_icons.sh /src /out

# ---------------------------------------------------------------------------- builder
FROM debian:bookworm-slim AS builder

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
      bzip2 coreutils \
    && rm -rf /var/lib/apt/lists/*

COPY --from=tools /fastdl-tools /usr/local/bin/fastdl-tools
COPY --from=model-compiler /out/mdlcompiler /usr/local/bin/mdlcompiler
COPY --from=icon-render /out /rendered-icons
COPY fastdl/tools/*.sh /tools/

ENV ICONS=/rendered-icons

# The compiler needs a -game directory with gameinfo.txt and writes into <game>/models/. A minimal
# tree is enough; it never reads the game's own content.
ENV GAME_DIR=/gamedir/insurgency
RUN mkdir -p "$GAME_DIR/models" \
    && printf '"GameInfo"\n{\n\tgame "INSURGENCY"\n\tFileSystem\n\t{\n\t\tSteamAppId 222880\n\t\tSearchPaths { game "|gameinfo_path|." }\n\t}\n}\n' \
       > "$GAME_DIR/gameinfo.txt"

ARG FASTDL_SERVER=test

COPY fastdl/src /src
COPY ["server config/${FASTDL_SERVER}/opt/insurgency-server/insurgency/scripts/theaters", "/theaters"]

# Placeholders for materials custom maps reference but never packed - a failed VMT lookup is not
# cached, so the client retries every frame and the framerate collapses. Shared across servers, and
# the one group left unhashed because each map's BSP hardcodes the path.
# See fastdl/map_asset_stubs/README.md.
COPY fastdl/map_asset_stubs/materials /stubs

ARG MODEL_COMPILE=1
ENV MODEL_COMPILE=${MODEL_COMPILE}

RUN sh /tools/build.sh

# ---------------------------------------------------------------------------- published image
# scratch: mounted read-only as a k8s image volume, never executed. Content sits at the image ROOT
# so the mounted volume IS the document root and DOWNLOAD_URL needs nothing appended.
#
# An image with no command cannot be `docker run` - use `make inspect` to look inside.
FROM scratch AS fastdl
COPY --from=builder /fastdl /
