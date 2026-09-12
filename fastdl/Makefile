# Fast-download content image. Self-contained like tools/server-runner; see README.md.
#
# The build context is the REPO ROOT, because the theaters live under "server config/".

MAKEFLAGS += --no-print-directory
PROJECT_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
REPO_DIR := $(shell dirname $(PROJECT_DIR))

SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

VERSION ?= 0.0.1-dev
CONTAINER_REGISTRY ?= tug2
SERVER ?= test

IMAGE = $(CONTAINER_REGISTRY)/insurgency-$(SERVER)-fastdl:$(VERSION)
DOCKERFILE = $(PROJECT_DIR)/Dockerfile

##@ General

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development

.PHONY: fmt
fmt: ## Run go fmt against the build tools.
	go fmt -C "$(PROJECT_DIR)/tools" ./...

.PHONY: vet
vet: ## Run go vet against the build tools.
	go vet -C "$(PROJECT_DIR)/tools" ./...

.PHONY: tools
tools: fmt vet ## Build the build tools locally (they normally build inside the image).
	go build -C "$(PROJECT_DIR)/tools" -o "$(PROJECT_DIR)/tools/fastdl-tools"

##@ Build

.PHONY: content
content: ## Build the content image: compile textures and models, then publish under hashed paths.
	docker build -f "$(DOCKERFILE)" --target fastdl \
	  --build-arg FASTDL_SERVER=$(SERVER) \
	  -t "$(IMAGE)" $(EXTRA_DOCKER_ARGS) --load "$(REPO_DIR)"

.PHONY: content-no-models
content-no-models: ## Build without recompiling models (textures and materials only).
	docker build -f "$(DOCKERFILE)" --target fastdl \
	  --build-arg FASTDL_SERVER=$(SERVER) --build-arg MODEL_COMPILE=0 \
	  -t "$(IMAGE)" $(EXTRA_DOCKER_ARGS) --load "$(REPO_DIR)"

.PHONY: icon
icon: ## Render the buy-menu icons and copy them to build/icons/ to check framing.
	@# Framing is by eye: nothing records the camera the original icon used. Tune yaw/pitch/margin in
	@# src/vgui/*.render.txt, re-run this, and compare against the shipped icon.
	@docker build -f "$(DOCKERFILE)" --target icon-render -t "$(IMAGE)-icons" $(EXTRA_DOCKER_ARGS) "$(REPO_DIR)"
	@rm -rf "$(PROJECT_DIR)/build/icons" && mkdir -p "$(PROJECT_DIR)/build/icons"
	@cid=$$(docker create "$(IMAGE)-icons" true) && \
	  docker cp "$$cid:/out/." "$(PROJECT_DIR)/build/icons/" > /dev/null && \
	  docker rm -f "$$cid" > /dev/null
	@ls -la "$(PROJECT_DIR)/build/icons/"
	@echo "Rendered to fastdl/build/icons/ - compare framing against the shipped icon."

.PHONY: inspect
inspect: ## Build the builder stage and list what would be published.
	@docker build -f "$(DOCKERFILE)" --target builder \
	  --build-arg FASTDL_SERVER=$(SERVER) -t "$(IMAGE)-inspect" $(EXTRA_DOCKER_ARGS) "$(REPO_DIR)" > /dev/null
	@docker run --rm "$(IMAGE)-inspect" sh -c 'cat /fastdl/manifest.json; echo; find /fastdl -type f ! -name "*.bz2" | sort'

##@ Maintenance

.PHONY: clean
clean: ## Remove built images.
	@rm -rf "$(PROJECT_DIR)/build"
	@docker image rm -f "$(IMAGE)" "$(IMAGE)-inspect" "$(IMAGE)-icons" > /dev/null 2>&1 || true
