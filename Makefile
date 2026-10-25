MAKEFLAGS += --no-print-directory
PROJECT_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))

PUSH_ALL ?= false
VERSION = 0.0.1-dev
CONTAINER_REGISTRY = tug2
CONTAINER_REPOSITORY = $(CONTAINER_REGISTRY)/insurgency
PUSH_ARG = $(if $(findstring t,$(PUSH_ALL)),--push)
DOCKER_ARGS = --build-arg SERVER_RUNNER_IMAGE_NAME=$(CONTAINER_REGISTRY)/server-runner:latest

# Records which commit a pushed image was built from: after a successful push, HEAD is tagged with the
# image name minus the "insurgency-" prefix plus its tag, e.g. test-0.0.27-dev. Forced, so pushing the
# same VERSION again moves the tag along with the registry tag it mirrors. Annotated, with the full
# image reference as the message, because tag.gpgsign makes git refuse a tag without one. Local only -
# push tags yourself. Expands to nothing unless PUSH_ALL is set.
# Usage: $(call tag-pushed-image,GIT_TAG,IMAGE_REFERENCE)
define tag-pushed-image
$(if $(PUSH_ARG),@git -C "$(PROJECT_DIR)" diff --quiet HEAD || echo "  warning: uncommitted changes are in the pushed image but not in $(1)"
@git -C "$(PROJECT_DIR)" tag -f -a -m "$(2)" "$(1)" > /dev/null && echo "  tagged $$(git -C "$(PROJECT_DIR)" rev-parse --short HEAD) as $(1)")
endef

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

# The workshop items each server ships are pinned in workshop.lock.json. The Dockerfile stages that
# fetch them are generated from it and committed; each server's appworkshop_222880.acf is generated
# from it at build time and is not. See
# tools/workshop/workshop_lock.py for what the buckets are for.
.PHONY: workshop-lock
workshop-lock:	## Re-pin every subscribed workshop item to the version Steam serves now.
	python3 "$(PROJECT_DIR)/tools/workshop/workshop_lock.py" refresh
	@$(MAKE) workshop-render

.PHONY: workshop-render
workshop-render:	## Regenerate the Dockerfile stages and .acf files that follow from the lockfile.
	python3 "$(PROJECT_DIR)/tools/workshop/workshop_lock.py" render

.PHONY: workshop-check
workshop-check:	## Fail if the committed Dockerfile does not match the lockfile.
	python3 "$(PROJECT_DIR)/tools/workshop/workshop_lock.py" check

# Servers that ship player-downloadable content over fastdl. Only these get a fastdl image; every
# other server runs stock content and needs neither the image nor the advertising plugin.
# The theaters the servers load are flattened from theaters/src/ and the vendored TUG theaters they
# #base (theaters/vendor/), and committed under server config/. See tools/theater-build/build.py.
.PHONY: theater-build
theater-build:	## Regenerate the flattened theaters from theaters/src/ and theaters/vendor/.
	python3 "$(PROJECT_DIR)/tools/theater-build/build.py" build

.PHONY: theater-check
theater-check:	## Fail if a committed flattened theater does not match its sources.
	python3 "$(PROJECT_DIR)/tools/theater-build/build.py" check

FASTDL_SERVERS ?= test

# The fast-download content image is its own project (fastdl/Makefile, fastdl/Dockerfile), built
# and published independently - see fastdl/README.md. These targets just delegate so the top-level
# entry points keep working.
.PHONY: fastdl-image-%
fastdl-image-%:	## Build the fast-download content image for a server. Usage: make fastdl-image-SERVER_NAME
	@$(MAKE) theater-check
	$(MAKE) -C "$(PROJECT_DIR)/fastdl" content SERVER=$* VERSION=$(VERSION) \
	  CONTAINER_REGISTRY=$(CONTAINER_REGISTRY) EXTRA_DOCKER_ARGS="$(PUSH_ARG) $(EXTRA_DOCKER_ARGS)"
	$(call tag-pushed-image,$*-fastdl-$(VERSION),$(CONTAINER_REPOSITORY)-$*-fastdl:$(VERSION))

.PHONY: fastdl-images
fastdl-images: $(addprefix fastdl-image-,$(FASTDL_SERVERS))	## Build every fast-download content image.

.PHONY: server-image-%
server-image-%: base-image Dockerfile	## Build the container image for the specified server. Usage: make server-image-SERVER_NAME
	@# Built together for convenience, not because they are coupled. The server reads the file list
	@# and the theater name out of manifest.json on the fastdl host at map start, so the content image
	@# can be rebuilt and republished on its own - `make fastdl-image-test` - and a running server
	@# picks the change up on its next map change without a rebuild or a redeploy.
	$(if $(filter $*,$(FASTDL_SERVERS)),$(MAKE) fastdl-image-$*,@echo "  $* does not use fastdl, skipping its content image")
	@# The workshop stages are committed in the Dockerfile, so a stale copy has to fail rather than
	@# ship the wrong items. The .acf files are not committed - they are build output, written fresh
	@# from the lockfile here so it stays the only source of truth.
	@$(MAKE) workshop-check
	@$(MAKE) workshop-render
	@$(MAKE) theater-check
	docker build --target gameserver-$* -t "$(CONTAINER_REPOSITORY)-$*:$(VERSION)" $(PUSH_ARG) --load $(DOCKER_ARGS) $(EXTRA_DOCKER_ARGS) "$(PROJECT_DIR)"
	$(call tag-pushed-image,$*-$(VERSION),$(CONTAINER_REPOSITORY)-$*:$(VERSION))

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
