# This produces a container with the Insurgency server already installed. This prevents installation from occuring on every single startup. The tradeoff is a much
# larger (10 GB) container image with copyrighted content, which can't be pushed to public repos (e.g. ghcr.io, dockerhub)

# This produces a Linux container image, but the Insurgency server is actually a Windows x64 binary running under Wine.
# As a result, plugins and mods must be the Windows versions.
# This approach fixes several issues with the Linux version of the Insurgency server, including:
# * The 32-bit Linux server has a memory leak when downloading or checking workshop items, causing it to hit the 4 GB memory limit and crash.
# * The Linux server has undocumented Linux kernel requirements, causing it to crash on some modern kernels (such as those used by default by Talos).

# The Windows x64 version of the Insurgency server runs fine under Wine, but SourceMod has a bug with it (see https://github.com/alliedmodders/sourcemod/issues/2370),
# so the 32-bit version and 32-bit plugins are used instead.

ARG SERVER_RUNNER_IMAGE_NAME=ghcr.io/soliddowant/server-runner:latest
ARG METAMOD_VERSION=1.12.0-git1219
ARG SOURCEMOD_VERSION=1.12.0-git7217
ARG SOURCEMOD_COMMIT=1059132fe9b390728743faf26b3f8a2 # SourceMod 1.12.0-git7217

FROM ghcr.io/gameservermanagers/steamcmd:ubuntu-24.04 AS gameserver-builder

RUN \
    # Install the game files (Windows x64 version)
    mkdir -p /opt/insurgency-server && \
    # Note: error message "Error! App '237410' state is 0x202 after update job." means not enough disk space.
    steamcmd +force_install_dir /opt/insurgency-server +login anonymous +@sSteamCmdForcePlatformType windows +app_update 237410 validate +quit && \
    # Link console.log to /opt/insurgency-server/run/console.log to allow it to be stored on another filesystem (like a memory-backed filesystem)
    # This will keep it from filling up the disk, and not wear out the drive with constant writes.
    ln -s /opt/insurgency-server/run/console.log /opt/insurgency-server/insurgency/console.log && \
    # Remove files for other platforms (keep Windows files)
    rm -rf /opt/insurgency-server/srcds{_linux,_osx,_osx64,_run} && \
    find /opt/insurgency-server/ \( -name '*.dylib' -or -name 'osx64' -or -name '*.so' \) -delete && \
    # Remove the joystick config file to reduce logging noise
    rm -f /opt/insurgency-server/insurgency/cfg/joystick.cfg

# This is a trick to get the /opt/insurgency-server directory in the gameserver stage owned by 1000:1000.
# By copying this empty directory with `chown=1000:1000` to /opt/insurgency-server, the following copies
# to /opt/insurgency-server do not modify the directory owner. This allows the server to run at 1000:1000
# without having the ability to overwrite existing files (such as libraries loaded with `dlopen`).
RUN mkdir /empty-directory

FROM ghcr.io/gameservermanagers/steamcmd:ubuntu-24.04 AS gameserver-mods-base

RUN \
    # Install curl and unzip for downloading mods
    apt update && \
    DEBIAN_FRONTEND=noninteractive apt install --no-install-recommends -y curl ca-certificates unzip && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir /insurgency

# Example mod download:
#
# FROM gameserver-mods-base AS gameserver-mods-someplugin
#
# RUN \
#    mkdir -p /plugins/someplugin && \
#    curl -fsSL -o /insurgency/addons/someplugin.so https://example.com/someplugin.so && \
#    curl -fsSL -o /insurgency/addons/someplugin/someplugin.txt https://example.com/someplugin.txt

FROM gameserver-mods-base AS gameserver-mods-metamod

# MetaMod Source (Windows version)
ARG METAMOD_VERSION
RUN \
    curl -fsSL -o /tmp/mmsource.zip https://mms.alliedmods.net/mmsdrop/1.12/mmsource-${METAMOD_VERSION}-windows.zip && \
    unzip -q /tmp/mmsource.zip -d /insurgency && \
    rm /tmp/mmsource.zip && \
    # Remove extra files
    rm -rf /insurgency/addons/metamod_x64.vdf && \
    rm -rf /insurgency/addons/metamod/{README.txt,metaplugins.ini} && \
    rm -rf /insurgency/addons/metamod/bin/win64 && \
    find /insurgency/addons/metamod/bin -name 'metamod.2.*.dll' -not -name 'metamod.2.insurgency.dll' -delete && \
    find /insurgency -type d -exec chmod 755 {} \;

# Build SourceMod extensions
FROM ubuntu:24.04 AS sourcemod-extensions-ripext

ARG RIPEXT_VERSION=1.3.2

RUN \
    apt update && \
    DEBIAN_FRONTEND=noninteractive apt install --no-install-recommends -y \
        curl ca-certificates unzip

# Download and extract ripext extensions
RUN \
    mkdir /insurgency && \
    curl -fsSL -o /tmp/ripext.zip https://github.com/ErikMinekus/sm-ripext/releases/download/1.3.2/sm-ripext-${RIPEXT_VERSION}-windows.zip && \
    unzip -q /tmp/ripext.zip -d /insurgency && \
    rm /tmp/ripext.zip

FROM gameserver-mods-base AS gameserver-mods-sourcemod

# SourceMod (Windows version)
ARG SOURCEMOD_VERSION
RUN \
    --mount=type=bind,source=./plugins/sourcemod,target=/plugin-source \
    --mount=from=sourcemod-extensions-ripext,target=/plugin-extensions/ripext \
    curl -fsSL -o /tmp/sourcemod.zip https://sm.alliedmods.net/smdrop/1.12/sourcemod-${SOURCEMOD_VERSION}-windows.zip && \
    unzip -q /tmp/sourcemod.zip -d /insurgency && \
    rm /tmp/sourcemod.zip && \
    # Disable auto updates
    sed -i 's/^\(.*"DisableAutoUpdate"[[:space:]]*\)"no"/\1"yes"/' /insurgency/addons/sourcemod/configs/core.cfg && \
    # Copy in the sourcemod extensions
    cp -r /plugin-extensions/ripext/insurgency / && \
    # Remove extra files
    rm -rf /insurgency/addons/sourcemod/*.txt && \
    rm -rf /insurgency/sourcemod/bin/x64 && \
    find /insurgency/addons/sourcemod/bin -name 'sourcemod.2.*.dll' -not -name 'sourcemod.2.insurgency.dll' -delete && \
    rm -rf /insurgency/addons/sourcemod/extensions/x64 && \
    find /insurgency/addons/sourcemod/bin -name 'game.*.ext.2.*.dll' -not -name 'game.insurgency.ext.2.insurgency.dll' -delete && \
    find /insurgency/addons/sourcemod/bin -name 'sdkhooks.ext.2.*.dll' -not -name 'sdkhooks.ext.2.insurgency.dll' -delete && \
    find /insurgency/addons/sourcemod/bin -name 'sdktools.ext.2.*.dll' -not -name 'sdktools.ext.2.insurgency.dll' -delete && \
    rm -rf /insurgency/addons/sourcemod/gamedata/{sm-tf2.games.txt,sm-cstrike.games} && \
    find /insurgency/addons/sourcemod/gamedata -name 'engine.*.txt' -not -name 'engine.insurgency.txt' -delete && \
    find /insurgency/addons/sourcemod/gamedata -name 'game.*.txt' -not -name 'game.insurgency.txt' -delete && \
    rm -rf /insurgency/addons/sourcemod/logs && \
    rm -rf /insurgency/addons/sourcemod/plugins/nextmap.smx && \
    rm -rf /insurgency/addons/sourcemod/scripting && \
    find /insurgency/addons/sourcemod/translations -name 'nextmap.phrases.txt' -delete && \
    # Copy in the modified, idempotent SQL scripts
    cp -r /plugin-source/configs/sql-init-scripts/pgsql/create_admins.sql /insurgency/addons/sourcemod/configs/sql-init-scripts/pgsql/create_admins.sql && \
    cp -r /plugin-source/configs/sql-init-scripts/pgsql/clientprefs-pgsql.sql /insurgency/addons/sourcemod/configs/sql-init-scripts/pgsql/clientprefs-pgsql.sql && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \;

# This target is used to compile SourceMod plugins.
FROM ubuntu:24.04 AS sourcemod-plugins-base

# Download SourceMod for the compiler
ARG SOURCEMOD_VERSION
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
    curl -fsSL -o - https://sm.alliedmods.net/smdrop/1.12/sourcemod-${SOURCEMOD_VERSION}-linux.tar.gz \
    | tar -xz -C /sourcemod && \
    # Create output dirs
    mkdir -p /insurgency/addons/sourcemod/plugins/disabled /insurgency/cfg

FROM sourcemod-plugins-base AS sourcemod-plugins-battleye-disabler

# Build the Battleye disabler plugin
RUN \
    mkdir /plugin-source && \
    curl -fsSL -o /plugin-source/ins_battleye_disabler.sp https://raw.githubusercontent.com/Grey83/SourceMod-plugins/a9e0230f3ae554633b349a56eb6474208ae16c84/SM/scripting/ins_battleye_disabler%201.0.0.sp && \
    /sourcemod/addons/sourcemod/scripting/spcomp /plugin-source/ins_battleye_disabler.sp -o /insurgency/addons/sourcemod/plugins/ins_battleye_disabler.smx && \
    rm -rf /plugin-source && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-marquis-fix

# Build the marquis map fix plugin
RUN \
    mkdir /plugin-source && \
    curl -fsSL -o /plugin-source/marquis_fix.sp https://raw.githubusercontent.com/NullifidianSF/insurgency_public/e6eb683a6ba407b5bba29b74817e0c0bcb9d6a0c/addons/sourcemod/scripting/marquis_fix.sp && \
    /sourcemod/addons/sourcemod/scripting/spcomp /plugin-source/marquis_fix.sp -o /insurgency/addons/sourcemod/plugins/disabled/marquis_fix.smx && \
    rm -rf /plugin-source && \
    # Create a config file to only load this plugin when the marquis map is running
    echo "sm plugins load disabled/marquis_fix.smx"  > /insurgency/cfg/server_marquis.cfg && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-citadel-coop-spawn-fix

# Build the citadel coop spawn fix plugin
RUN \
    mkdir /plugin-source && \
    curl -fsSL -o /plugin-source/citadel_coop_spawn_fix.sp https://raw.githubusercontent.com/NullifidianSF/insurgency_public/e6eb683a6ba407b5bba29b74817e0c0bcb9d6a0c/addons/sourcemod/scripting/citadel_coop_spawn_fix.sp && \
    /sourcemod/addons/sourcemod/scripting/spcomp /plugin-source/citadel_coop_spawn_fix.sp -o /insurgency/addons/sourcemod/plugins/disabled/citadel_coop_spawn_fix.smx && \
    rm -rf /plugin-source && \
    # Create a config file to only load this plugin when the citadel_coop map is running
    echo "sm plugins load disabled/citadel_coop_spawn_fix.smx"  > /insurgency/cfg/server_citadel_coop.cfg && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-counterattack-countdown

# Build the counter attack countdown plugin
RUN --mount=type=bind,source=./plugins/sourcemod/scripting/include,target=/plugin-source/scripting/include \
    curl -fsSL -o /plugin-source/ca_countdown.sp https://raw.githubusercontent.com/NullifidianSF/insurgency_public/e6eb683a6ba407b5bba29b74817e0c0bcb9d6a0c/addons/sourcemod/scripting/ca_countdown.sp && \
    /sourcemod/addons/sourcemod/scripting/spcomp /plugin-source/ca_countdown.sp -i /plugin-source/scripting/include -o /insurgency/addons/sourcemod/plugins/ca_countdown.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-bot-names

# Build the bot name plugin
RUN \
    mkdir -p /plugin-source /insurgency/addons/sourcemod/configs/botnames && \
    curl -fsSL -o /plugin-source/bot_names.sp https://raw.githubusercontent.com/thecannons/Insurgency-dy-sourcemod/594f5d321010da16cc0ad78478921af4d80cfa80/scripting/botnames.sp && \
    curl -fsSL -o /insurgency/addons/sourcemod/configs/botnames/arabic.txt https://raw.githubusercontent.com/thecannons/Insurgency-dy-sourcemod/594f5d321010da16cc0ad78478921af4d80cfa80/configs/botnames/arabic.txt && \
    curl -fsSL -o /insurgency/addons/sourcemod/configs/botnames/default.txt https://raw.githubusercontent.com/thecannons/Insurgency-dy-sourcemod/594f5d321010da16cc0ad78478921af4d80cfa80/configs/botnames/default.txt && \
    curl -fsSL -o /insurgency/addons/sourcemod/configs/botnames/pashto.txt https://raw.githubusercontent.com/thecannons/Insurgency-dy-sourcemod/594f5d321010da16cc0ad78478921af4d80cfa80/configs/botnames/pashto.txt && \
    /sourcemod/addons/sourcemod/scripting/spcomp /plugin-source/bot_names.sp -o /insurgency/addons/sourcemod/plugins/bot_names.smx && \
    rm -rf /plugin-source && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-firesupport

# Build the fire support plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod,target=/plugin-source \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/FireSupport.sp -o /insurgency/addons/sourcemod/plugins/FireSupport.smx && \
    mkdir -p /insurgency/addons/sourcemod/translations && \
    cp /plugin-source/translations/firesupport.phrases.txt /insurgency/addons/sourcemod/translations/ && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-databasemigrator

# Build the database migration plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod/scripting,target=/plugin-source/scripting \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/DatabaseMigrator.sp -o /insurgency/addons/sourcemod/plugins/DatabaseMigrator.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-loadoutsaver

# Build the loadout saver plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod,target=/plugin-source \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/LoadoutSaver.sp -o /insurgency/addons/sourcemod/plugins/LoadoutSaver.smx && \
    mkdir -p /insurgency/addons/sourcemod/configs/sql-init-scripts/pgsql && \
    cp /plugin-source/configs/sql-init-scripts/pgsql/loadout_saver.sql /insurgency/addons/sourcemod/configs/sql-init-scripts/pgsql/loadout_saver.sql && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-restrictedarea

# Build the restricted area removal plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod/scripting,target=/plugin-source/scripting \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/restrictedarea.sp -o /insurgency/addons/sourcemod/plugins/restrictedarea.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-bot-flashlights

# Build the bot flashlight plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod/scripting,target=/plugin-source/scripting \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/bot_flashlights.sp -o /insurgency/addons/sourcemod/plugins/bot_flashlights.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-teamflash

# Build the teamflash plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod/scripting,target=/plugin-source/scripting \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/teamflash.sp -o /insurgency/addons/sourcemod/plugins/teamflash.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-punitive-persistence

# Build the punitive persistence plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod,target=/plugin-source \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/punitive_persistence.sp -o /insurgency/addons/sourcemod/plugins/punitive_persistence.smx && \
    mkdir -p /insurgency/addons/sourcemod/configs/sql-init-scripts/pgsql && \
    cp /plugin-source/configs/sql-init-scripts/pgsql/punitive_persistence.sql /insurgency/addons/sourcemod/configs/sql-init-scripts/pgsql/punitive_persistence.sql && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-map-logger

# Build the map logger plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod,target=/plugin-source \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/map_logger.sp -o /insurgency/addons/sourcemod/plugins/map_logger.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-gg2-weapon-spam

# Build the gg2_weapon_spam plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod/scripting,target=/plugin-source/scripting \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/gg2_weapon_spam.sp -o /insurgency/addons/sourcemod/plugins/gg2_weapon_spam.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-gg2-admin-logger

# Build the gg2_admin_logger plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod/scripting,target=/plugin-source/scripting \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/gg2_admin_logger.sp -o /insurgency/addons/sourcemod/plugins/gg2_admin_logger.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-gg2-burn

# Build the gg2_burn plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod/scripting,target=/plugin-source/scripting \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/gg2_burn.sp -o /insurgency/addons/sourcemod/plugins/gg2_burn.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-gg2-cache-protect

# Build the gg2_cache_protect plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod/scripting,target=/plugin-source/scripting \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/gg2_cache_protect.sp -o /insurgency/addons/sourcemod/plugins/gg2_cache_protect.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-gg2-connection-tracker

# Build the gg2_connection_tracker plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod/scripting,target=/plugin-source/scripting \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/gg2_connection_tracker.sp -o /insurgency/addons/sourcemod/plugins/gg2_connection_tracker.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-gg2-damage

# Build the gg2_damage plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod/scripting,target=/plugin-source/scripting \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/gg2_damage.sp -o /insurgency/addons/sourcemod/plugins/gg2_damage.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-gg2-discord

# Build the gg2_discord plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod/scripting,target=/plugin-source/scripting \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/gg2_discord.sp -o /insurgency/addons/sourcemod/plugins/gg2_discord.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-gg2-forceauthorize

# Build the gg2_forceauthorize plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod/scripting,target=/plugin-source/scripting \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/gg2_forceauthorize.sp -o /insurgency/addons/sourcemod/plugins/gg2_forceauthorize.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-gg2-forceretry

# Build the gg2_forceretry plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod/scripting,target=/plugin-source/scripting \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/gg2_forceretry.sp -o /insurgency/addons/sourcemod/plugins/gg2_forceretry.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-gg2-fuckyeah

# Build the gg2_fuckyeah plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod/scripting,target=/plugin-source/scripting \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/gg2_fuckyeah.sp -o /insurgency/addons/sourcemod/plugins/gg2_fuckyeah.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-gg2-insurgency

# Build the gg2_insurgency plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod/scripting,target=/plugin-source/scripting \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/gg2_insurgency.sp -o /insurgency/addons/sourcemod/plugins/gg2_insurgency.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-gg2-kill-entities

# Build the gg2_kill_entities plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod/scripting,target=/plugin-source/scripting \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/gg2_kill_entities.sp -o /insurgency/addons/sourcemod/plugins/gg2_kill_entities.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-gg2-map-changeups

# Build the gg2_map_changeups plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod/scripting,target=/plugin-source/scripting \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/gg2_map_changeups.sp -o /insurgency/addons/sourcemod/plugins/gg2_map_changeups.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-gg2-medic-tracker

# Build the gg2_medic_tracker plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod/scripting,target=/plugin-source/scripting \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/gg2_medic_tracker.sp -o /insurgency/addons/sourcemod/plugins/gg2_medic_tracker.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-gg2-messages

# Build the gg2_messages plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod/scripting,target=/plugin-source/scripting \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/gg2_messages.sp -o /insurgency/addons/sourcemod/plugins/gg2_messages.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-gg2-mstats2

# Build the gg2_mstats2 plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod/scripting,target=/plugin-source/scripting \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/gg2_mstats2.sp -o /insurgency/addons/sourcemod/plugins/gg2_mstats2.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-gg2-playlist-hax

# Build the gg2_playlist_hax plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod/scripting,target=/plugin-source/scripting \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/gg2_playlist_hax.sp -o /insurgency/addons/sourcemod/plugins/gg2_playlist_hax.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-gg2-show-health-simp

# Build the gg2_show_health_simp plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod/scripting,target=/plugin-source/scripting \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/gg2_show_health_simp.sp -o /insurgency/addons/sourcemod/plugins/gg2_show_health_simp.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-gg2-spectator

# Build the gg2_spectator plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod/scripting,target=/plugin-source/scripting \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/gg2_spectator.sp -o /insurgency/addons/sourcemod/plugins/gg2_spectator.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-gg2-supply

# Build the gg2_supply plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod/scripting,target=/plugin-source/scripting \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/gg2_supply.sp -o /insurgency/addons/sourcemod/plugins/gg2_supply.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-gg2-teamkill

# Build the gg2_teamkill plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod/scripting,target=/plugin-source/scripting \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/gg2_teamkill.sp -o /insurgency/addons/sourcemod/plugins/gg2_teamkill.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-gg2-theater-items

# Build the gg2_theater_items plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod/scripting,target=/plugin-source/scripting \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/gg2_theater_items.sp -o /insurgency/addons/sourcemod/plugins/gg2_theater_items.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

FROM sourcemod-plugins-base AS sourcemod-plugins-gg2-votekick-immunity

# Build the gg2_votekick_immunity plugin
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod/scripting,target=/plugin-source/scripting \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/gg2_votekick_immunity.sp -o /insurgency/addons/sourcemod/plugins/gg2_votekick_immunity.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

# Medic, respawns, stat tracking, bot respawns, dynamic difficulty adjustment, name role prefixes, dependency on inslib
FROM sourcemod-plugins-base AS sourcemod-plugins-everythingelse

# Build the "everything else" plugins
COPY plugins/sourcemod/gamedata/ /insurgency/addons/sourcemod/gamedata/
RUN --mount=type=bind,source=./plugins/sourcemod,target=/plugin-source \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/gg2_insurgency.sp -o /insurgency/addons/sourcemod/plugins/gg2_insurgency.smx && \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/bm2_respawn.sp -o /insurgency/addons/sourcemod/plugins/bm2_respawn.smx && \
    mkdir -p /insurgency/cfg && \
    touch /insurgency/cfg/plugin.respawn.cfg && \
    mkdir -p /insurgency/addons/sourcemod/translations && \
    cp /plugin-source/translations/nearest_player.phrases.txt /plugin-source/translations/respawn.phrases.txt /insurgency/addons/sourcemod/translations && \
    /sourcemod/addons/sourcemod/scripting/spcomp --include=/plugin-source/scripting/include  /plugin-source/scripting/d_dy_pull_rag.sp -o /insurgency/addons/sourcemod/plugins/d_dy_pull_rag.smx && \
    # Fixup file permissions
    find /insurgency -type d -exec chmod 755 {} \; && \
    find /insurgency -type f -exec chmod 644 {} \;

# Dumb workaround for docker limitation where you can't copy from an image specified by a build arg
FROM ${SERVER_RUNNER_IMAGE_NAME} AS server-runner

# Using Ubuntu 25:05 is needed for new enough for Wine support for the Windows x64 server
FROM ubuntu:25.04 AS gameserver

RUN \
    dpkg --add-architecture i386 && \
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
    ca-certificates \
    wine \
    wine32:i386 \
    winbind \
    libwine \
    fonts-wine  \
    xvfb \
    xauth \
    x11-utils && \
    rm -rf /var/lib/apt/lists/*

# Copy the game server files
COPY --from=gameserver-builder --chown=1000:1000 /empty-directory /opt/insurgency-server
COPY --from=gameserver-builder /opt/insurgency-server/ /opt/insurgency-server/

# Copy the tool used for providing env vars as args
# If this errors, verify that the server-runner image was built.
COPY --from=server-runner /server-runner /usr/bin/server-runner

# Copy in plugins
COPY --from=gameserver-mods-metamod --chown=0:0 /insurgency /opt/insurgency-server/insurgency/
COPY --from=gameserver-mods-sourcemod --chown=0:0 /insurgency /opt/insurgency-server/insurgency/
# TODO symlink this or configure source mod to write this elsewhere
COPY --from=gameserver-builder --chown=1000:1000 --chmod=755 /empty-directory /opt/insurgency-server/insurgency/addons/sourcemod/logs

# Copy in compiled plugins
COPY --from=sourcemod-plugins-battleye-disabler --chown=0:0 /insurgency /opt/insurgency-server/insurgency/

# Copy the default config
COPY ["server config/base/", "/"]

# Setup Wine environment
# Unfortunately due to Wine ownership checks, this forces the container to run as this SPECIFIC UID:GID.
USER 1000:1000

ENV WINEARCH=win32
ENV WINEPREFIX=/home/ubuntu/.wine
ENV XDG_RUNTIME_DIR=/home/ubuntu/.local/share

RUN \
    mkdir -p "${WINEPREFIX}" "${XDG_RUNTIME_DIR}" && \
    wine wineboot --init && wineserver --wait

ENV SERVER_CONFIG_FILE_PATH=server.cfg
# This is the max that the game allows and determines how many bots can exist at once
ENV MAX_PLAYERS=49
ENV STARTING_MAP=embassy_coop
ENV PORT=27015

WORKDIR /opt/insurgency-server/run

# GAME_SERVER_LOGIN_TOKEN (https://docs.linuxgsm.com/steamcmd/gslt) args will be added by server administrator
# RCON_PASSWORD args will be added by server administrator
# Arg reference: https://developer.valvesoftware.com/wiki/Command_line_options#Source_Dedicated_Server
ENTRYPOINT [    \
    "server-runner",  \
    "-rcon-port", "${PORT}", \
    "-rcon-password", "${RCON_PASSWORD}", \
    "--", \
    "wine", \
    "/opt/insurgency-server/srcds.exe", \
    "-condebug", \
    "-ip", "0.0.0.0", \
    "-game", "insurgency", \
    "-tickrate", "64", \
    "-workshop",    \
    "-norestart",   \
    "-maxplayers", "${MAX_PLAYERS}", \
    "-strictportbind",  \
    "-port", "${PORT}", \
    "-nohltv", \
    "+sv_setsteamaccount", "${GAME_SERVER_LOGIN_TOKEN}",   \
    "+rcon_password", "${RCON_PASSWORD}",   \
    "+servercfgfile", "${SERVER_CONFIG_FILE_PATH}",    \
    "+map", "${STARTING_MAP}",  \
    "+sv_pure", "0" \
]

FROM gameserver AS gameserver-main

# Start the server once to generate any missing files (like workshop items), then exit
# Adding `+quit` to the CLI will cause the server to segfault, but this can be safely ignored.
COPY ["server config/main/opt/insurgency-server/insurgency/subscribed_file_ids.txt", "/opt/insurgency-server/insurgency/subscribed_file_ids.txt"]

# Start the server once to generate any missing files (like workshop items), then exit
# Adding `+quit` to the CLI will cause the server to segfault, but this can be safely ignored.
# Note: Running as user 1000:1000 (inherited from base stage) - Wine prefix was created with proper ownership
RUN server-runner -- wine /opt/insurgency-server/srcds.exe -condebug -game insurgency -workshop +servercfgfile server.cfg +map embassy_coop +quit

# Copy in the map-specific plugins
COPY --from=sourcemod-plugins-marquis-fix --chown=0:0 /insurgency /opt/insurgency-server/insurgency/
COPY --from=sourcemod-plugins-citadel-coop-spawn-fix --chown=0:0 /insurgency /opt/insurgency-server/insurgency/
COPY --from=sourcemod-plugins-firesupport --chown=0:0 /insurgency /opt/insurgency-server/insurgency/
COPY --from=sourcemod-plugins-databasemigrator --chown=0:0 /insurgency /opt/insurgency-server/insurgency/
COPY --from=sourcemod-plugins-loadoutsaver --chown=0:0 /insurgency /opt/insurgency-server/insurgency/
COPY --from=sourcemod-plugins-counterattack-countdown --chown=0:0 /insurgency /opt/insurgency-server/insurgency/
COPY --from=sourcemod-plugins-gg2-restrictedarea --chown=0:0 /insurgency /opt/insurgency-server/insurgency/
COPY --from=sourcemod-plugins-bot-flashlights --chown=0:0 /insurgency /opt/insurgency-server/insurgency/
COPY --from=sourcemod-plugins-bot-names --chown=0:0 /insurgency /opt/insurgency-server/insurgency/
COPY --from=sourcemod-plugins-teamflash --chown=0:0 /insurgency /opt/insurgency-server/insurgency/
COPY --from=sourcemod-plugins-punitive-persistence --chown=0:0 /insurgency /opt/insurgency-server/insurgency/
COPY --from=sourcemod-plugins-map-logger --chown=0:0 /insurgency /opt/insurgency-server/insurgency/
COPY --from=sourcemod-plugins-everythingelse --chown=0:0 /insurgency /opt/insurgency-server/insurgency/

# Copy in the remaining main config files
COPY ["server config/main/", "/"]
