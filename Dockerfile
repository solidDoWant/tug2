# This produces a container with the insurgency server already installed. This prevents installation from occuring on every single startup. The tradeoff is a much
# larger (10 GB) container image with copyrighted content, which can't be pushed to public repos (e.g. ghcr.io, dockerhub)

FROM ghcr.io/gameservermanagers/steamcmd:ubuntu-24.04 AS gameserver-builder

RUN \
    # Install the game files
    mkdir -p /opt/insurgency-server && \
    # Note: error message "Error! App '237410' state is 0x202 after update job." means not enough disk space.
    steamcmd +force_install_dir /opt/insurgency-server +login anonymous +app_update 237410 validate +quit && \
    # Remove files for other platforms
    rm -rf /opt/insurgency-server/srcds{.exe,_osx,_osx64,_x64.exe,_run} && \
    find /opt/insurgency-server/ \( -name '*.dll' -or -name '*.exe' -or -name '*.dylib' -or -name 'osx64' \) -delete && \
    # Remove the joystick config file to reduce logging noise
    rm -f /opt/insurgency-server/insurgency/cfg/joystick.cfg

# This is a trick to get the /opt/insurgency-server directory in the gameserver stage owned by 1000:1000.
# By copying this empty directory with `chown=1000:1000` to /opt/insurgency-server, the following copies
# to /opt/insurgency-server do not modify the directory owner. This allows the server to run at 1000:1000
# without having the ability to overwrite existing files (such as libraries loaded with `dlopen`).
RUN mkdir /empty-directory

FROM ghcr.io/gameservermanagers/steamcmd:ubuntu-24.04 AS gameserver-mods

# TODO this will be used to download workshop mods, third party plugins, etc.

# Example workshop mod download:
# RUN steamcmd +login anonymous +workshop_download_item 222880 123456789

# Example third party plugin download:
# RUN \
#    mkdir -p /plugins/someplugin && \
#    curl -fsSL -o /plugins/someplugin/someplugin.so https://example.com/someplugin.so && \
#    curl -fsSL -o /plugins/someplugin/someplugin.txt https://example.com/someplugin.txt

RUN \
    # Install curl for downloading mods
    apt update && \
    DEBIAN_FRONTEND=noninteractive apt install --no-install-recommends -y curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir /plugins

# MetaMod Source
RUN \
    mkdir -p /plugins/mmsource && \
    curl -fsSL -o - https://mms.alliedmods.net/mmsdrop/1.12/mmsource-1.12.0-git1219-linux.tar.gz \
    | tar -xz -C /plugins/mmsource && \
    # Remove extra files
    rm -rf /plugins/mmsource/addons/metamod/bin/linux64 /plugins/mmsource/addons/metamod/readme.txt /plugins/mmsource/addons/metamod_x64.vdf && \
    find /plugins/mmsource/addons/metamod/bin -name '*.so' -not \( -name 'server.so' -or -name 'server_i486.so' -or -name 'metamod.2.insurgency.so' \) -delete && \
    # Fixup file permissions
    find /plugins/mmsource -type d -exec chmod 755 {} \; && \
    find /plugins/mmsource -type f -name "*.so" -exec chmod 755 {} \; && \
    find /plugins/mmsource -type f -not -name "*.so" -exec chmod 644 {} \;

# SourceMod
RUN \
    mkdir -p /plugins/sourcemod && \
    curl -fsSL -o - https://sm.alliedmods.net/smdrop/1.12/sourcemod-1.12.0-git7217-linux.tar.gz \
    | tar -xz -C /plugins/sourcemod && \
    # Remove extra files
    rm -rf /plugins/sourcemod/addons/sourcemod/bin/x64 /plugins/sourcemod/addons/sourcemod/logs && \
    find /plugins/sourcemod/addons/sourcemod/bin -name '*.so' -not \( -name 'sourcemod.2.insurgency.so' -or -name 'sourcemod_mm_i486.so' -or -name 'sourcemod_mm.x64.so' -or -name 'sourcemod.logic.so' -or -name 'sourcepawn.jit.x86.so' \) -delete && \
    # Fixup file permissions
    find /plugins/sourcemod -type d -exec chmod 755 {} \; && \
    find /plugins/sourcemod -type f -name "*.so" -exec chmod 755 {} \; && \
    find /plugins/sourcemod -type f -not -name "*.so" -exec chmod 644 {} \;

# This target is used to compile SourceMod plugins.
FROM ubuntu:24.04 AS gameserver-compiled-mods

# Download SourceMod for the compiler

RUN \
    dpkg --add-architecture i386 && \
    apt update && \
    DEBIAN_FRONTEND=noninteractive apt install --no-install-recommends -y \
        # Used for downloading resources
        curl ca-certificates \
        # Needed by the SourceMod compiler
        libc6:i386 lib32stdc++6 && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /sourcemod && \
    curl -fsSL -o - https://sm.alliedmods.net/smdrop/1.12/sourcemod-1.12.0-git7217-linux.tar.gz \
    | tar -xz -C /sourcemod && \
    # Output dir
    mkdir -p /plugins/sourcemod/addons/sourcemod/plugins

# Build the Battleye disabler plugin
RUN \
    mkdir -p /plugins-source/ins_battleye_disabler && \
    curl -fsSL -o /plugins-source/ins_battleye_disabler/ins_battleye_disabler.sp https://raw.githubusercontent.com/Grey83/SourceMod-plugins/a9e0230f3ae554633b349a56eb6474208ae16c84/SM/scripting/ins_battleye_disabler%201.0.0.sp && \
    /sourcemod/addons/sourcemod/scripting/spcomp /plugins-source/ins_battleye_disabler/ins_battleye_disabler.sp -o /plugins/sourcemod/addons/sourcemod/plugins/ins_battleye_disabler.smx && \
    rm -rf /plugins-source/ins_battleye_disabler

# Build the annoucement plugin
RUN \
    mkdir -p /plugins-source/announcement && \
    curl -fsSL -o /plugins-source/announcement/announcement.sp https://raw.githubusercontent.com/rrrfffrrr/Insurgency-server-plugins/refs/heads/master/scripting/announcement.sp && \
    /sourcemod/addons/sourcemod/scripting/spcomp /plugins-source/announcement/announcement.sp -o /plugins/sourcemod/addons/sourcemod/plugins/announcement.smx && \
    echo "Welcome to TUG!" > /plugins/sourcemod/addons/sourcemod/announcement.txt && \
    rm -rf /plugins-source/announcement

# Fixup file permissions
RUN \
    find /plugins/sourcemod -type d -exec chmod 755 {} \; && \
    find /plugins/sourcemod -type f -name "*.so" -exec chmod 755 {} \; && \
    find /plugins/sourcemod -type f -not -name "*.so" -exec chmod 644 {} \;

# This must use an older debian image. Newer images cause the server to segfault on startup, because for some
# reason the server attempts to allocate more than 4GB of memory and fails.
# TODO see if this can be updated at all. Testing takes a long time (about an hour per test), so I'm holding off for now.
FROM debian:jessie AS gameserver

USER 1000:1000

# Copy the game server files
COPY --from=gameserver-builder --chown=1000:1000 /empty-directory /opt/insurgency-server
COPY --from=gameserver-builder /opt/insurgency-server/ /opt/insurgency-server/

# Copy i386 ld. The server executable is 32 bit and specifies this interpreter, making it incompatible
# with the 64 bit interpreter and libraries.
COPY --from=gameserver-builder /usr/lib/ld-linux.so.2 /lib/ld-linux.so.2
COPY --from=gameserver-builder /usr/lib/i386-linux-gnu /lib/i386-linux-gnu

# Copy the tool used for providing env vars as args
# If this errors, verify that the env-runner image was built.
COPY --from=ghcr.io/soliddowant/env-runner /env-runner /usr/bin/env-runner

# Copy in plugins
COPY --from=gameserver-mods --chown=0:0 /plugins/mmsource/ /opt/insurgency-server/insurgency/
COPY --from=gameserver-mods --chown=0:0 /plugins/sourcemod/ /opt/insurgency-server/insurgency/
# TODO symlink this or configure source mod to write this elsewhere
COPY --from=gameserver-builder --chown=1000:1000 --chmod=755 /empty-directory /opt/insurgency-server/insurgency/addons/sourcemod/logs

# Copy in compiled plugins
COPY --from=gameserver-compiled-mods --chown=0:0 /plugins/sourcemod/ /opt/insurgency-server/insurgency/

# Copy TLS certs
COPY --from=gameserver-builder /etc/ssl/certs/ /etc/ssl/certs/
COPY --from=gameserver-builder /usr/share/ca-certificates/ /usr/share/ca-certificates/

# Copy the default config
COPY ["server config/base/", "/"]

ENV LD_LIBRARY_PATH=/opt/insurgency-server:/opt/insurgency-server/bin
ENV SERVER_CONFIG_FILE_PATH=server.cfg
ENV MAX_PLAYERS=24
ENV STARTING_MAP=embassy_coop

# GAME_SERVER_LOGIN_TOKEN (https://docs.linuxgsm.com/steamcmd/gslt) args will be added by server administrator
# RCON_PASSWORD args will be added by server administrator
# Arg reference: https://developer.valvesoftware.com/wiki/Command_line_options#Source_Dedicated_Server
ENTRYPOINT [    \
    "env-runner",  \
    "/opt/insurgency-server/srcds_linux", \
    "-game", "-insurgency", \
    "-tickrate", "64", \
    "-workshop",    \
    "-norestart",   \
    "-maxplayers", "${MAX_PLAYERS}", \
    "+sv_setsteamaccount", "${GAME_SERVER_LOGIN_TOKEN}",   \
    "+rcon_password", "${RCON_PASSWORD}",   \
    "+servercfgfile", "${SERVER_CONFIG_FILE_PATH}",    \
    "+map", "${STARTING_MAP}"  \
]

FROM gameserver AS gameserver-main

COPY ["server config/main/", "/"]
