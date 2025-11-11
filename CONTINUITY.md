# Server continuity documentation

This is a semi-technical document describing what needs to be done to get the server back online in the even that the existing server becomes unavailable and the current sysadmin is unreachable.

To be able to effectively execute this plan, you must have at least a rudementary technical understanding of the following:
* Linux server management
  * Running CLI commands
  * Creating and operating services
  * Debugging basic performance issues like resource exhaustion
* Containers
  * Building
  * Starting, stopping, replacing
  * Ideally orchestration but not required
* Networking
  * Firewalls and NAT
  * TCP handshake
* PostgreSQL database management
  * Creating database instances
  * Creating databases
  * Backing up and restoring databases
* Security
  * Expect the server to be compromised given the age, lack of patches, and known bugs
  * Compromise impact ("blast radius") must be limited to avoid pivoting to other systems, persisting

**PLEASE UNDERSTAND** that running an Insurgency server isn't quite as simple as a lot of other game servers and hosted services for several reasons:
* The server executable itself is not technically capable of using more than 4GB of RAM (no you can't change this), and it will frequently run near this limit under load (plugins + full set of players)
* The 64-bit Windows version (there is no 64-bit Linux version) is not compatible with some SourceMod plugins, and SourceMod itself only fixed compatibility a few days ago
* Even by modern game standards, a full install of the game server is absolutely enormous (50+ GB just for the server + content)
* The Linux version of the server has a memory leak that will cause the server to crash upon startup after adding more than about 70 workshop items (the current build has around 240)
* The game wants to "verify" workshop items on every single restart, making server restarts take a long time without workarounds
* The Windows version wraps the "console" in its own GUI, making it a huge pain to run on headless servers

This leads to an extremely complicated process for getting the server up and running. This is not just a simple "download this file and double click" operation, this is a "follow this long
and difficult guide and hope you know what you're doing or don't run into issues" operation. When reviewing the contents of this repo, be aware that every choice regarding how the system works was
made **very** deliberately and carefully. The problem of running a server is complicated, which tends to lead to a complex solution.

## Overview

Here are the steps in broad strokes for standing up a new server that is production-ready (stable, intended for public use, and sufficiently performant):

1. Choose a hosting provider.
2. Create a server (computer server, not game server) instance.
3. Create a Postgres database cluster/instance on your server or via your hosting provider.
4. Fork this GitHub repo and make changes as appropriate (e.g. change name, add and remove admins, update database connection details).
5. Create all actual Postgres databases needed for the server.
6. Create a container registry on your server or via your hosting provider.
7. Build a game server container image, and push it to your container registry.
8. On your server, download ("pull") your built container image and run it.
9. Configure your hosting provider's network and server's firewall rules to allow access to the game server.

## Choosing a hosting provider

This may sound easy, but is really really difficult to get right in practice. You need to balance the following:
* Up-front and continuing costs (OpEx and CapEx) for the server, related resources
  * Buying or renting a server
  * Internet traffic costs (including possibly eating costs for DoS attacks)
  * Hosted service (container registry, Postgres instance) costs
  * Support
* Time you'll need to spend both setting up and managing the server
  * Will it take 10 up-front hours? 50? 100?
  * Will you need to spend an hour a week on average maintaining it once set up? 5? 10?
* Provider availability, maintenance windows, including:
  * Provider outages
  * Forced maintenance for provided services
  * Some hardware failures (e.g. physical disk failures if using a local disk)
* Physical datacenter location, and how it affects the server's average and p95 latency to/from users
  * East coast USA = lag for Russia, China, India, Australia
  * West coast USA = lag for Europe
  * Europe hosting = lag for USA
* Performance - you are responsible for:
  * Lag spikes due to single-core CPU performance, noisy neighbors causing CPU cache eviction
  * Disk latency when using highly-availalbe, networked storage
  * NUMA latency
* Monitoring and metrics available out of the box vs what you need to setup yourself
  * Without this you won't know when there is an issue
  * Without this you won't know if you're over- or under-sizing (and paying)

High cost hosting providers that are highly available and relatively easy to get started with:
* [AWS](https://aws.amazon.com/)
* [Azure](https://azure.microsoft.com/en-us/)
* [GCP](https://cloud.google.com/)

All of these providers will give you pretty much whatever you're willing to pay for, and have managed versions of Postgres
and container registries. They are **extremely** expensive for this workload, but once you learn the basics of their
ecosystem, it's easy to setup whatever you like pretty quickly.

Don't use Oracle - they're know for terminating accounts with no notice.

Lower cost hosting providers:
* [OVHcloud](https://us.ovhcloud.com/)
* [Fly.io](https://fly.io)
* [PlanetScale](https://planetscale.com/) (DB only, $5/month pricing coming soon)
* TODO add other options

OVHcloud cost estimate, all hosted:
* $21/month for container registry
* $55/month for database, no redundency
* $13/month for basic server, no data redundency

This comes out to about $100/month. The two most expensive costs, container registry and database hosting, could be dropped
in exchange for running these on the server itself and managing them. This would likely require a more expensive server.

**This is not a recommendation**. It's just meant to illustrate a *remotely* reasonable cost estimate for this, if using a
hosting provider instead of self-hosting.

## Create a server instance

The server itself needs an absolute minimum of 60 GB of disk space, and realistically several times this. I'd recommend
budgeting 4 GB of RAM for the game server process itself, and another couple for the OS. The game server only has a couple
of threads and mostly runs on a single core, so there isn't much benefit for adding more cores for the server itself. Instead,
focus on CPUs with higher single-threaded performance as opposed to more threads/cores.

If you're hosting everything on your own server (e.g. container registry and more importantly a database instance), you'll need
additional resources (CPU cores, RAM, disk capacity and performance).

I'd recommend using one of the following for the OS:
* Ubuntu
* Debian
  * Does not get new package versions very often, can make certain bugs harder to fix
* NixOS
  * Very steep learning curve
  * You can skip most of the server instance setup by deploying [this OS config](https://github.com/solidDoWant/infra-mk3/blob/89c40423fb6bfbfa86034a50eae4f44da0a83921/cluster/gitops/tug2/insurgency/server/nix/os-config/configuration.nix)

Actually creating a new server is hosting-provider specific, so I'll leave this as an exercise for the reader.

I would highly recommend that SSH access be IP-restricted, and/or use public-key cryptography (GPG keys, x509 certs) for authentication.

Once the server is running and you can access it, you'll need to install [Docker](https://docs.docker.com/engine/install/).

## Create a Postgres database cluster/instance

If you're using your hosting provider's managed Postgres service (e.g. RDS for AWS), follow the docs on their website for setup.
The advantage of using a managed service is the ease of setup and maintenance, but your wallet will pay for it.

You can alternatively run a Postgres database on your server instance. This puts you in charge of setup and maintenance for it,
but is substantially cheaper than most hosted alternatives. Here are a couple of appraoches to running PostgreSQL locally:
* [Official docs](https://www.postgresql.org/docs/current/admin.html)
* [Via a Docker container](https://www.docker.com/blog/how-to-use-the-postgres-docker-official-image/)
  * Does not include setting up a service to automatically start the Postgres database upon server reboot

## Fork this repo and make changes as needed

Setup a GitHub account if you don't already have one and fork this repo. Then, update the following:
* The [database config file](./server%20config/main/opt/insurgency-server/insurgency/addons/sourcemod/configs/databases.cfg)
* The [list of authorized admins](./server%20config/main/opt/insurgency-server/insurgency/addons/sourcemod/configs/admins.cfg)
* The [server name](./server%20config/main/opt/insurgency-server/insurgency/cfg/server.cfg) and any other config

**Be aware that anything you commit is publicly visible, including passwords**. To avoid storing passwords in git and baking
them into the container image, I have set the database configuration to point to a local `envoy` container, which proxies
database connections and handles authentication. Envoy pulls database credentials from a non-public file at startup, so nothing
ends up in source control.

## Create a container registry

This will be used to host game server container builds. While rebuilding upon every game server startup is possible, it takes
a long time (30 to 60 minutes typically). As with Postgres, you can use a manged service, or self-host. The tradeoffs are 
essentially the same as with Postgres.

To avoid potential copyright issues, it is important to use a private registry that requires authentiction to pull images. **DO
NOT JUST USE PUBLIC DOCKERHUB** or you'll be redistributing copyrighted material.

You'll also need to figure out a way to prune the container registry regularly, or you'll eat a lost of storage (and cost)
storing old and unused images. Most providers have a built-in mechanism for this - check their docs if using a managed service.

If self-hosting, your best bet is probably [distribution](https://github.com/distribution/distribution) or [Harbor](https://github.com/goharbor/harbor).
Harbor is pretty "heavy" (requiring more resources to run) and uses distribution under the hood, but also provides some niceties
like a web UI, and automatic image pruning.

Be aware that because container image builds are 50GB each, you'll want to budget for a couple hundred GB of storage.

## Build and push the game server image

Once the repo is forked, updated, and a container registry is deployed, you can now build and push game server container image
builds. Container images are "snapshots" of _everything_ that the server needs to run, from the game server itself, to system
libraries, to configuration and mods. From within a local copy of your forked repo, you can run this to build and push a
container image:

`make server-images VERSION=0.0.1-dev CONTAINER_REGISTRY=<put your registry here>/tug2 PUSH_ALL=true`

Initial builds take a long time (30m to an hour), but subsequent builds should usually take much less due to caching.

## Pull and run the server

With the image built and docker installed on your server, you can now download ("pull") the container image and run it. You
can do this via:

`docker run --rm -it -p 27015:27015 -e "RCON_PASSWORD=YOUR_RCON_PASSWORD" "<put your registry here>/tug2/insurgency-main:0.0.1-dev"`

Alternatively you can do this via a Docker Compose file. I have an example [here](https://github.com/solidDoWant/infra-mk3/blob/89c40423fb6bfbfa86034a50eae4f44da0a83921/cluster/gitops/tug2/insurgency/server/docker-compose/docker-compose.yaml).

To run this upon every server start, you'll need to create a systemd unit to bring the server up automatically. [Here's an
example of how to do this](https://blog.container-solutions.com/running-docker-containers-with-systemd).

## Configure firewalls to forward traffic and test

Once the server is running, you can configure your provider to forward traffic to the process. If you have a public IP address
assigned directly to the server, then you probably just need to configure your provider to allow port 27015 UDP traffic to the
server. If you're using a NAT gateway or a load balancer, more config may be required - check with your provider's docs for details.
