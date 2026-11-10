FROM mcr.microsoft.com/devcontainers/go:2-1.27-bookworm

# The base image's Go can trail the patch release a module requires (go.mod
# "go 1.27.4" on a 1.27.3 image). "auto" lets the go command fetch the exact
# toolchain a module asks for, instead of refusing to build with "local".
ENV GOTOOLCHAIN=auto

# Keep in sync with SOURCEMOD_VERSION in the repository's root Dockerfile.
ARG SOURCEMOD_VERSION=1.12.0-git7259
ARG SOURCEMOD_RELEASE=1.12.0.7259

RUN \
    # Agree to steamcmd license
    echo steam steam/question select "I AGREE" | debconf-set-selections && \
    echo steam steam/license note '' | debconf-set-selections && \
    # Install steamcmd
    dpkg --add-architecture i386 && \
    sed -i 's/Components: main/& contrib non-free/' /etc/apt/sources.list.d/debian.sources && \
    apt update && \
    DEBIAN_FRONTEND=noninteractive apt install --no-install-recommends -y steamcmd && \
    ln -s /usr/games/steamcmd /usr/local/bin/steamcmd

# Install linuxgsm for local use
# Pinned by digest; the server image no longer uses this base, so this is only for the local linuxgsm script.
COPY --from=ghcr.io/gameservermanagers/gameserver:ins@sha256:59cbec3bf83fd068c4f415c66baf26690d95a6a8f57d58774ece6c439c4662a8 /app/linuxgsm.sh /usr/local/bin/linuxgsm

RUN \
    # Install [Dive](https://github.com/wagoodman/dive) for inspecting container images
    curl -fsSL -o /tmp/dive.deb https://github.com/wagoodman/dive/releases/download/v0.13.1/dive_0.13.1_linux_amd64.deb && \
    dpkg -i /tmp/dive.deb && \
    rm -rf /tmp/dive.deb

# Install SourceMod for the compiler
RUN \
    apt update && \
    DEBIAN_FRONTEND=noninteractive apt install --no-install-recommends -y \
    lib32gcc-s1 \
    lib32stdc++6 && \
    mkdir -p /opt/sourcemod && \
    curl -fsSL -o - https://github.com/alliedmodders/sourcemod/releases/download/${SOURCEMOD_RELEASE}/sourcemod-${SOURCEMOD_VERSION}-linux.tar.gz | \
    tar -xzf - -C /opt/sourcemod && \
    ln -s /opt/sourcemod/addons/sourcemod/scripting/spcomp64 /usr/local/bin/smcompiler && \
    ln -s /opt/sourcemod/addons/sourcemod/scripting/spcomp64 /usr/local/bin/spcomp
