# SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
# SPDX-License-Identifier: MIT
#
# lookout-marine on the reMarkable — the build and deploy front door.
#
#   make image      # once: bake the reMarkable SDK (Qt6 + epaper) into an image
#   make            # -> build-rm2-sdk/lookout-marine  (device-Qt epaper binary)
#   make deploy     # copy it + your charts to the tablet
#   make run        # build + deploy + launch on the device
#   make host       # a desktop build, for iterating on the UI
#
# The CHART CORE is cross-compiled by Zig on the host, not in the container:
# `zig build lib -Dbackend=none` produces a static archive for any target
# without a toolchain to install. The container is only there for the SDK's Qt.
-include config.mk

DEVICE      ?= rm2
HOST        ?= root@10.11.99.1
CHART       ?= charts
IMAGE       ?= lookout-marine-sdk:$(DEVICE)
BUILD       ?= build-$(DEVICE)-sdk
REPO        ?= $(abspath ..)

# Where the cross-built core lands. Kept apart from the repo's own zig-out so a
# device build never clobbers the host one.
CORE_PREFIX ?= $(REPO)/zig-out-$(DEVICE)

# The rM2 is an i.MX7 — Cortex-A7, armv7 hard-float — on a 5.4 kernel with
# glibc 2.31. Naming the glibc floor keeps the archive loadable on stock
# firmware instead of tracking the host's newer one.
ZIG_TARGET  ?= arm-linux-gnueabihf.2.31
ZIG_CPU     ?= cortex_a7

# Strip stray whitespace from CLI/config.mk overrides so it cannot leak into
# image tags, directory names or ssh arguments.
DEVICE := $(strip $(DEVICE))
HOST   := $(strip $(HOST))
CHART  := $(strip $(CHART))
IMAGE  := $(strip $(IMAGE))
BUILD  := $(strip $(BUILD))

# Build the container for the host's NATIVE arch — linux/arm64 on an Apple
# Silicon Mac, linux/amd64 on x86_64 — so nothing is emulated.
ifeq ($(shell uname -m),x86_64)
  PLATFORM  ?= linux/amd64
  SDK_ARCH  := x86_64
else
  PLATFORM  ?= linux/arm64
  SDK_ARCH  := aarch64
endif

# The current rM2 SDK (firmware 3.27.0.97), picked for the host arch, so
# `make image` works with no setup. Override SDK_URL for other firmware;
# `make sdk-url` prints what will be used. https://developer.remarkable.com/links
ifeq ($(strip $(DEVICE)),rm2)
  SDK_URL   ?= https://storage.googleapis.com/remarkable-codex-toolchain/3.27.0.97/rm2/remarkable-production-image-5.7.119-rm2-public-$(SDK_ARCH)-toolchain.sh
endif

.DEFAULT_GOAL := build
.PHONY: help sdk-url core core-host image build deploy run host shell clean

help: ## show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-10s\033[0m %s\n", $$1, $$2}'

sdk-url: ## print the reMarkable SDK URL `make image` will use
	@[ -n "$(SDK_URL)" ] && echo "$(SDK_URL)" || \
	  echo "no default for DEVICE=$(DEVICE) — set SDK_URL (https://developer.remarkable.com/links)"

core: ## cross-build the chart core for the device (Zig; no toolchain needed)
	@command -v zig >/dev/null 2>&1 || { echo "zig not found — brew install zig"; exit 2; }
	cd $(REPO) && zig build lib -Dbackend=none \
	  -Dtarget=$(ZIG_TARGET) -Dcpu=$(ZIG_CPU) -p $(CORE_PREFIX)

core-host: ## build the chart core for this machine (for `make host`)
	@command -v zig >/dev/null 2>&1 || { echo "zig not found — brew install zig"; exit 2; }
	cd $(REPO) && zig build lib -Dbackend=none

image: ## (re)build the SDK Docker image; the SDK download is cached
	@[ -n "$(SDK_URL)" ] || { echo "no default SDK_URL for DEVICE=$(DEVICE); set SDK_URL=<installer .sh URL>"; exit 2; }
	DOCKER_BUILDKIT=1 docker build --platform $(PLATFORM) --build-arg SDK_URL="$(SDK_URL)" \
	  -f docker/Dockerfile.sdk -t $(IMAGE) .

build: core ## cross-build the epaper binary in Docker (incremental; CLEAN=1 to reset)
	@docker image inspect $(IMAGE) >/dev/null 2>&1 || $(MAKE) image
	docker run --rm --platform $(PLATFORM) -e CLEAN=$(CLEAN) \
	  -v "$(CURDIR)":/work -v "$(CORE_PREFIX)":/core:ro \
	  $(IMAGE) /work/docker/sdk-build.sh $(DEVICE)

deploy: ## copy the binary, the launcher and the charts to the tablet
	scripts/deploy.sh $(BUILD)/lookout-marine $(CHART) $(HOST)

run: build deploy ## build, deploy, then launch on the device (epaper)
	ssh -t $(HOST) '/home/root/lookout-marine/launch.sh /home/root/lookout-marine/charts'

host: core-host ## a desktop build, for iterating on the UI (needs local Qt 6)
	cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
	cmake --build build

shell: ## open a shell in the SDK image (for debugging the build)
	docker run --rm -it --platform $(PLATFORM) \
	  -v "$(CURDIR)":/work -v "$(CORE_PREFIX)":/core:ro $(IMAGE) bash

clean: ## remove build outputs (keeps the SDK image)
	rm -rf $(BUILD) build $(CORE_PREFIX)
