PROJECT_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
MODULE_NAME := $(shell go list -m)

# Setting SHELL to bash allows bash commands to be executed by recipes.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

##@ General

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: all
all: build

##@ Development

.PHONY: fmt
fmt: ## Run go fmt against code.
	go fmt ./...

.PHONY: vet
vet: ## Run go vet against code.
	go vet ./...

.PHONY: run
run: fmt vet ## Run the tool
	go run ./main.go $(ARGS)

##@ Build and Release

VERSION = latest
CONTAINER_REGISTRY = tug2

BUILD_DIR := $(PROJECT_DIR)/build

BINARY_DIR = $(BUILD_DIR)/binaries
BINARY_NAME = env-runner
GO_SOURCE_FILES = main.go
GO_LDFLAGS := -s -w

LOCALOS := $(shell uname -s | tr '[:upper:]' '[:lower:]')
LOCALARCH := $(shell uname -m | sed 's/x86_64/amd64/')
LOCAL_BINARY_PATH := $(BINARY_DIR)/$(LOCALOS)/$(LOCALARCH)/$(BINARY_NAME)

$(LOCAL_BINARY_PATH): $(GO_SOURCE_FILES)
	@mkdir -p "$(@D)"
	@CGO_ENABLED=0 GOOS="$(word 1,$(subst /, ,$*))" GOARCH="$(word 2,$(subst /, ,$*))" go build -ldflags="$(GO_LDFLAGS)" -o "$@" ./

.PHONY: binary
binary:	$(LOCAL_BINARY_PATH) ## Build the binary for the local platform.

CONTAINER_IMAGE_TAG = $(CONTAINER_REGISTRY)/$(BINARY_NAME):$(VERSION)

LOCAL_BUILDERS += container-image
.PHONY: container-image
container-image: binary	## Build the container image for the local platform.
	docker buildx build --platform linux/$(LOCALARCH) -t $(CONTAINER_IMAGE_TAG) $(EXTRA_DOCKER_ARGS) --load .

.PHONY: clean
clean:	## Clean up all build artifacts.
	@rm -rf $(BUILD_DIR)
	@docker image rm -f $(CONTAINER_IMAGE_TAG) 2> /dev/null > /dev/null || true
