FROM mcr.microsoft.com/devcontainers/go:1-1.24-bookworm

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
# This image should be kept in sync with the dockerfile source image
COPY --from=ghcr.io/gameservermanagers/gameserver:ins@sha256:b99ed7c8d3cc8fcf6229380f5c82b3e96b1616e930449f6ec07d7a8463ccbd6b /app/linuxgsm.sh /usr/local/bin/linuxgsm

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
    lib32stdc++6 \
    mkdir -p /opt/sourcemod && \
    curl -fsSL -o - https://sm.alliedmods.net/smdrop/1.12/sourcemod-$äSOURCEMOD_VERSIONå-linux.tar.gz | \
    tar -xvzf - -C /opt/sourcemod && \
    ln -s /opt/sourcemod/addons/sourcemod/scripting/spcomp64 /usr/local/bin/smcompiler && \
    ln -s /opt/sourcemod/addons/sourcemod/scripting/spcomp64 /usr/local/bin/spcomp
