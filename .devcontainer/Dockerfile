FROM mcr.microsoft.com/devcontainers/go:2-1.27-bookworm@sha256:57d71ff964ee9ece1e8158b7379a5a0922f9a709a5aa2109115f7546be430bd7

# The base image's Go can trail the patch release a module requires (go.mod
# "go 1.27.4" on a 1.27.3 image). "auto" lets the go command fetch the exact
# toolchain a module asks for, instead of refusing to build with "local".
ENV GOTOOLCHAIN=auto

# Keep in sync with SOURCEMOD_VERSION in the repository's root Dockerfile (Renovate updates both in
# one PR; the checksum is updated by hand, see the root Dockerfile).
# renovate: datasource=github-releases depName=alliedmodders/sourcemod versioning=loose
ARG SOURCEMOD_VERSION=1.12.0.7260
ARG SOURCEMOD_SHA256=1025717c46119c15c6e73fd9b4a190fd8da480987307d133e1281eb9a6f5c91c

# renovate: datasource=github-release-attachments depName=wagoodman/dive
ARG DIVE_VERSION=v0.13.1
ARG DIVE_DIGEST=0c20d18f0cc87e6e982a3289712ac3aa9fc364ba973109d1da3a473232640571

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
COPY --from=ghcr.io/gameservermanagers/gameserver:ins@sha256:0b24766159ae2c97ebf7bfc2c6922bab97fee55a0d671762b460fc4dc75eb620 /app/linuxgsm.sh /usr/local/bin/linuxgsm

RUN \
    # Install [Dive](https://github.com/wagoodman/dive) for inspecting container images
    curl -fsSL -o /tmp/dive.deb "https://github.com/wagoodman/dive/releases/download/${DIVE_VERSION}/dive_${DIVE_VERSION#v}_linux_amd64.deb" && \
    echo "${DIVE_DIGEST}  /tmp/dive.deb" | sha256sum -c - && \
    dpkg -i /tmp/dive.deb && \
    rm -rf /tmp/dive.deb

# Install SourceMod for the compiler
RUN \
    apt update && \
    DEBIAN_FRONTEND=noninteractive apt install --no-install-recommends -y \
    lib32gcc-s1 \
    lib32stdc++6 && \
    mkdir -p /opt/sourcemod && \
    curl -fsSL -o /tmp/sourcemod.tar.gz "https://github.com/alliedmodders/sourcemod/releases/download/${SOURCEMOD_VERSION}/sourcemod-${SOURCEMOD_VERSION%.*}-git${SOURCEMOD_VERSION##*.}-linux.tar.gz" && \
    echo "${SOURCEMOD_SHA256}  /tmp/sourcemod.tar.gz" | sha256sum -c - && \
    tar -xzf /tmp/sourcemod.tar.gz -C /opt/sourcemod && \
    rm /tmp/sourcemod.tar.gz && \
    ln -s /opt/sourcemod/addons/sourcemod/scripting/spcomp64 /usr/local/bin/smcompiler && \
    ln -s /opt/sourcemod/addons/sourcemod/scripting/spcomp64 /usr/local/bin/spcomp
