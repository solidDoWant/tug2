# TUG 2

This repo contains all configuration for the TUG 2/TUG.GG Insurgency server network.

This repo is available to allow community members to suggest and implement changes, while separating actual server hosting from the game config.

## How this works

TUG 2 servers are deployed as "containers" within the sysadmin's hosting environment. "Containers" are created from "container images" that are
essentially copies of _all_ files needed to run a game server. This includes:
* The game server itself
* All assets
* All configuration
* All workshop items, mods, and plugins

This repo defines what files should be included in each server's container image. When a change is made, new images are built and made available
for the hosting infrastructure to download and use. To avoid potential copyright issues, built images are not publicly available.

This approach makes it somewhat easy for anybody to propose a change, to track complete history of all changes to be publicly recorded, for others 
to reproduce this work, and for the community to move to another hosting provider if desired.

## Hosting infra

The servers are managed via a Kubernetes cluster comprised of several nodes. All nodes have modern 20 core CPUs, 96 GB of DDR5 RAM, enterprise
replicated storage, and redundent 10 Gbps interconnects. If one physical server fails or is taken offline for maintenance, the TUG servers will
automatically be restarted on another physical server. All servers share a sizable UPS.

Monitoring and alerting are setup to notify the sysadmin of issues. A status page may be made available in the future for users to verify if the
servers are available.

These node are not currently dedicated to the server, running around a thousand other containers. There is no power provider redundency, or 
Internet uplink redundency. This could lead to performance or availability issues. If this setup isn't sufficient, the sysadmin will investigate
moving to dedicated nodes and/or a colo datacenter.

### Remaining TODOs:
* Deploy servers, link to config here
* Figure out GSLT ownership (need community input)
* Document availability expectations
* Backups
* Checksum downloaded files

## How-to guides

### How do I use GitHub to propose changes?

Changes are implemented through GitHub's "pull request" (PR) feature. Here's a high level overview of what you need to do if you haven't used GitHub before:

1. Create a [GitHub](https://github.com/signup) account and [sign in](https://github.com/login).
2. Navigate to the file(s) you want to change. See below guides for identifying which file(s) you need to edit.
3. Click the pencil icon on the right side of the screen that shows "Fork this repository and edit this file" when you hover over it.
4. When prompted with "You need to fork this repository to propose changes.", click "Fork this repository". This should open a new editor pane.
5. Edit the file as needed.
6. When done editing, click the "Commit changes..." button in the upper right.
7. Type a meaningful title and description of the change, and click "propose change".
8. Click "Create pull request".
9. Fill out the text box with a description of what the change does, and why you want it.
10. Click "Create pull request", and wait for other community members to review it, leaving feedback and/or accepting and deploying the change.

### How do I change a server variable/setting/CVAR?

1. Identify which server(s) you want to change.
2. Navigate to `server config/<server name>/opt/insurgency-server/insurgency/cfg/server.cfg`.
3. Add, change, and/or remove variables as needed. A full list of variables is available [here](https://github.com/GameServerManagers/Game-Server-Configs/blob/1e9217e0e0a5a67a6ef14b68b3831a2e5fa97e2b/ins/cvars/full_cvar_list.txt).

### How do I add a workshop item (map, theater, weapons, etc)?

1. Identify which workshop item you want to install.
2. Navigate to `server config/<server name>/opt/insurgency-server/insurgency/subscribed_file_ids.txt`.
3. Add the workshop item's ID to the file. There should be one ID per line.

### How do I add third-party files like a custom plugin?

Most external files like plugins should be "referenced" by this repo, rather than stored in this repo. This helps prevent copyright issues. To add a "reference" to a third-party file:
1. Open the [Dockerfile](./Dockerfile) used to create the container images for all servers.
2. Edit the `gameserver-mods` target to download required files. See examples in the dockerfile for details.
3. Under whichever server(s) should use the third-party file, add a `COPY` command to copy from the `gameserver-mods` target to the `gameserver-<server name>` target, to whatever directory the file(s) should be installed to.
   The server root is at `/opt/insurgency-server`.

