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

.PHONY: server-image-%
server-image-%: base-image Dockerfile	## Build the container image for the specified server. Usage: make server-image-SERVER_NAME
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

##@ Workshop

# Insurgency enforces file consistency for theater files (sv_consistency, on by default and
# separate from sv_pure), so a client that does not have a byte-identical copy of a theater the
# server uses is refused at connect. Files baked into the server image cannot reach the client, so
# anything client-visible has to be published as a Workshop item - and Workshop items are VPKs.
WORKSHOP_APP_ID = 222880
WORKSHOP_SERVER ?= test
WORKSHOP_NAME ?= tug_custom_theaters
WORKSHOP_TITLE ?= TUG Custom Theaters
WORKSHOP_DESCRIPTION ?= Theater files for the TUG servers. Built from https://github.com/solidDoWant/tug2
# 0 creates a new item; set this to an existing ID to publish an update to it instead.
WORKSHOP_ITEM_ID ?= 3796695587
# 0 public, 1 friends only, 2 private. Defaults to private so a first publish is never accidentally public.
WORKSHOP_VISIBILITY ?= 0
WORKSHOP_BUILD_DIR = $(PROJECT_DIR)/build/workshop/$(WORKSHOP_NAME)
WORKSHOP_SOURCE_DIR = $(PROJECT_DIR)/server config/$(WORKSHOP_SERVER)/opt/insurgency-server/insurgency

.PHONY: workshop-package
workshop-package:	## Build a Workshop VPK of a server's custom theaters. Usage: make workshop-package [WORKSHOP_SERVER=test] [WORKSHOP_ITEM_ID=123]
	@test -d "$(WORKSHOP_SOURCE_DIR)/scripts/theaters" || (2>&1 echo "No scripts/theaters in server config/$(WORKSHOP_SERVER) - nothing to publish" && exit 1)
	rm -rf "$(WORKSHOP_BUILD_DIR)"
	mkdir -p "$(WORKSHOP_BUILD_DIR)/content/scripts/theaters"
	cp "$(WORKSHOP_SOURCE_DIR)/scripts/theaters/"*.theater "$(WORKSHOP_BUILD_DIR)/content/scripts/theaters/"
	python3 "$(PROJECT_DIR)/tools/workshop/pack_vpk.py" "$(WORKSHOP_BUILD_DIR)/content" "$(WORKSHOP_BUILD_DIR)/item" "$(WORKSHOP_NAME)"
	@rm -rf "$(WORKSHOP_BUILD_DIR)/content"
	@printf '"workshopitem"\n{\n\t"appid"\t\t\t"$(WORKSHOP_APP_ID)"\n\t"publishedfileid"\t"$(WORKSHOP_ITEM_ID)"\n\t"contentfolder"\t\t"%s"\n\t"visibility"\t\t"$(WORKSHOP_VISIBILITY)"\n\t"title"\t\t\t"$(WORKSHOP_TITLE)"\n\t"description"\t\t"$(WORKSHOP_DESCRIPTION)"\n\t"changenote"\t\t"Built from $(shell git -C "$(PROJECT_DIR)" rev-parse --short HEAD 2>/dev/null || echo unknown)"\n}\n' "$(WORKSHOP_BUILD_DIR)/item" > "$(WORKSHOP_BUILD_DIR)/$(WORKSHOP_NAME).vdf"
	@echo
	@echo "Item content : $(WORKSHOP_BUILD_DIR)/item"
	@echo "steamcmd VDF : $(WORKSHOP_BUILD_DIR)/$(WORKSHOP_NAME).vdf"
	@echo
	@echo "To publish (visibility is $(WORKSHOP_VISIBILITY); 0=public 1=friends 2=private):"
	@echo "  steamcmd +login <account> +workshop_build_item \"$(WORKSHOP_BUILD_DIR)/$(WORKSHOP_NAME).vdf\" +quit"
	@echo
	@echo "Publishing needs an account that owns Insurgency and has accepted the Workshop legal"
	@echo "agreement. For an update, re-run with WORKSHOP_ITEM_ID=<existing id>."
	@echo "After publishing, add the item ID to the server's subscribed_file_ids.txt so clients get it."

.PHONY: clean-workshop
clean-workshop:	## Remove built Workshop packages.
	rm -rf "$(PROJECT_DIR)/build/workshop"

##@ Testing

LOCAL_RCON_PASSWORD = password

.PHONY: start-local-server-%
start-local-server-%: server-image-%	## Start a local server container for testing. Usage: make start-local-server-SERVER_NAME
	@exec docker run --rm -it -p 27015:27015 -e "RCON_PASSWORD=$(LOCAL_RCON_PASSWORD)" "$(CONTAINER_REPOSITORY)-$*:$(VERSION)"

.PHONY: start-local-server
start-local-server: start-local-server-main	## Start a local server container for testing.

.PHONY: local-rcon-%
local-rcon-%:	## Connect to the local server's RCON. Usage: make local-rcon-SERVER_NAME
	@echo "Type ':q' to quit."
	@exec docker run --rm -it --network host outdead/rcon /rcon -a 127.0.0.1:27015 -p "$(LOCAL_RCON_PASSWORD)"

.PHONY: local-rcon
local-rcon: local-rcon-main	## Connect to the local server's RCON.
