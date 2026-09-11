MAKEFLAGS += --no-print-directory
PROJECT_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))

PUSH_ALL ?= false
VERSION = 0.0.1-dev
CONTAINER_REGISTRY = tug2
CONTAINER_REPOSITORY = $(CONTAINER_REGISTRY)/insurgency
PUSH_ARG = $(if $(findstring t,$(PUSH_ALL)),--push)
DOCKER_ARGS = --build-arg SERVER_RUNNER_IMAGE_NAME=$(CONTAINER_REGISTRY)/server-runner:latest

##@ General

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: populate-workshop-cache
populate-workshop-cache:	## Download a copy of the original TUG.GG workshop items locally.
	steamcmd '+runscript "$(PROJECT_DIR)/workshop cache/populate.txt"'
	rm -rf "$(PROJECT_DIR)/workshop cache/contents" && mkdir -p "$(PROJECT_DIR)/workshop cache/contents"
	mv "$${HOME}/.local/share/Steam/steamapps/workshop/content/222880/"* "$(PROJECT_DIR)/workshop cache/contents"

.PHONY: new-server-config
new-server-config:	## Create a new server config from the template. Usage: make new-server-config SERVER_NAME=my-server
	@test -n "$(SERVER_NAME)" || (2>&1 echo "Usage: make new-server-config SERVER_NAME=my-server" && exit 1)
	cp -r "$(PROJECT_DIR)/server config/_template" "$(PROJECT_DIR)/server config/$(SERVER_NAME)"

.PHONY: server-runner-image
server-runner-image:
	$(MAKE) -C "$(PROJECT_DIR)/tools/server-runner" container-image VERSION=latest

.PHONY: base-image
base-image: server-runner-image Dockerfile
	docker build --target gameserver -t "$(CONTAINER_REPOSITORY)-base:$(VERSION)" $(DOCKER_ARGS) $(EXTRA_DOCKER_ARGS) "$(PROJECT_DIR)"

# Servers that ship player-downloadable content over fastdl. Only these get a fastdl image; every
# other server runs stock content and needs neither the image nor the advertising plugin.
FASTDL_SERVERS ?= test

.PHONY: fastdl-image-%
fastdl-image-%:	Dockerfile ## Build the fast-download content image for a server. Usage: make fastdl-image-SERVER_NAME
	docker build --target fastdl-$* --build-arg FASTDL_SERVER=$* -t "$(CONTAINER_REPOSITORY)-fastdl-$*:$(VERSION)" $(PUSH_ARG) --load $(DOCKER_ARGS) $(EXTRA_DOCKER_ARGS) "$(PROJECT_DIR)"

.PHONY: fastdl-images
fastdl-images: $(addprefix fastdl-image-,$(FASTDL_SERVERS))	## Build every fast-download content image.

.PHONY: server-image-%
server-image-%: base-image Dockerfile	## Build the container image for the specified server. Usage: make server-image-SERVER_NAME
	@# The two have to be built together. The game server advertises exactly what this image serves,
	@# from a list generated inside it, so shipping one without the other means clients are told to
	@# fetch files that are not being served - or are served files nobody asks for.
	$(if $(filter $*,$(FASTDL_SERVERS)),$(MAKE) fastdl-image-$*,@echo "  $* does not use fastdl, skipping its content image")
	docker build --target gameserver-$* -t "$(CONTAINER_REPOSITORY)-$*:$(VERSION)" $(PUSH_ARG) --load $(DOCKER_ARGS) $(EXTRA_DOCKER_ARGS) "$(PROJECT_DIR)"

.PHONY: server-images
server-images: server-image-main server-image-test	## Build all server images.

.PHONY: print-name-server-image-%
print-name-server-image-%:	## Print the full name of the specified server image. Usage: make print-name-server-image-SERVER_NAME
	@echo "$(CONTAINER_REPOSITORY)-$*:$(VERSION)"

.PHONY: clean
clean:	## Clean up all built images and temporary files.
	@docker image rm -f "$(CONTAINER_REGISTRY)-base:$(VERSION)" 2> /dev/null > /dev/null || true
	@$(MAKE) -C "$(PROJECT_DIR)/tools/server-runner" clean

start-local-server: start-local-server-main	## Start a local server container for testing.

.PHONY: local-rcon-%
local-rcon-%:	## Connect to the local server's RCON. Usage: make local-rcon-SERVER_NAME
	@echo "Type ':q' to quit."
	@exec docker run --rm -it --network host outdead/rcon /rcon -a 127.0.0.1:27015 -p "$(LOCAL_RCON_PASSWORD)"

.PHONY: local-rcon
local-rcon: local-rcon-main	## Connect to the local server's RCON.
