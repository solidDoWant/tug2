MAKEFLAGS += --no-print-directory
PROJECT_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))

PUSH_ALL ?= false
VERSION = 0.0.1-dev
CONTAINER_REGISTRY = ghcr.io/soliddowant/tug2
PUSH_ARG = $(if $(findstring t,$(PUSH_ALL)),--push)

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

.PHONY: env-runner-image
env-runner-image:
	$(MAKE) -C "$(PROJECT_DIR)/tools/env-runner" container-image VERSION=latest

.PHONY: base-image
base-image: env-runner-image
	docker build --target gameserver -t "$(CONTAINER_REGISTRY)-base:$(VERSION)" $(EXTRA_DOCKER_ARGS) "$(PROJECT_DIR)"

.PHONY: server-image-%
server-image-%: base-image	## Build the container image for the specified server. Usage: make server-image-SERVER_NAME
	docker build --target gameserver-$* -t "$(CONTAINER_REGISTRY)-$*:$(VERSION)" $(PUSH_ARG) --load $(EXTRA_DOCKER_ARGS) "$(PROJECT_DIR)"

.PHONY: server-images
server-images: server-image-main	## Build all server images.

.PHONY: clean
clean:	## Clean up all built images and temporary files.
	@docker image rm -f "$(CONTAINER_REGISTRY)-base:$(VERSION)" 2> /dev/null > /dev/null || true
	@$(MAKE) -C "$(PROJECT_DIR)/tools/env-runner" clean
