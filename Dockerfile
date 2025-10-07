# This produces a container with the insurgency server already installed. This prevents installation from occuring on every single startup. The tradeoff is a much
# larger (10 GB) container image with copyrighted content, which can't be pushed to public repos (e.g. ghcr.io, dockerhub)

FROM ghcr.io/gameservermanagers/steamcmd:ubuntu-24.04 AS gameserver-builder

RUN \
    # Install the game files
    mkdir -p /opt/insurgency-server && \
    # Note: error message "Error! App '237410' state is 0x202 after update job." means not enough disk space.
    steamcmd +force_install_dir /opt/insurgency-server +login anonymous +app_update 237410 +quit && \
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

RUN \
    # Install curl for downloading mods
    apt update && \
    DEBIAN_FRONTEND=noninteractive apt install --no-install-recommends -y curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir /plugins

# Example workshop mod download:
# RUN steamcmd +login anonymous +workshop_download_item 222880 123456789

# Example third party plugin download:
# RUN \
#    mkdir -p /plugins/someplugin && \
#    curl -fsSL -o /plugins/someplugin/someplugin.so https://example.com/someplugin.so && \
#    curl -fsSL -o /plugins/someplugin/someplugin.txt https://example.com/someplugin.txt


FROM gcr.io/distroless/static-debian12 AS gameserver

USER 1000:1000

COPY --from=gameserver-builder --chown=1000:1000 /empty-directory /opt/insurgency-server
COPY --from=gameserver-builder /opt/insurgency-server/ /opt/insurgency-server/
# Copy i386 ld. The server executable is 32 bit and specifies this interpreter, making it incompatible
# with the 64 bit interpreter and libraries.
COPY --from=gameserver-builder /usr/lib/ld-linux.so.2 /lib/ld-linux.so.2
COPY --from=gameserver-builder /usr/lib/i386-linux-gnu /lib/i386-linux-gnu
# Copy the tool used for providing env vars as args
# If this errors, verify that the env-runner image was built.
COPY --from=ghcr.io/soliddowant/env-runner /env-runner /usr/bin/env-runner

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

ENV MAX_PLAYERS=14

COPY ["server config/main/", "/"]
