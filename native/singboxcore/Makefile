# Build c-shared library for Flutter / macOS (dlopen).
#
# Usage:
#   make              # host arch
#   make ARCH=amd64
#   make universal
#   make clean
#
# Flutter Xcode Run Script copies build/<arch|universal>/libsingboxcore.dylib
# into Contents/Frameworks of the .app bundle.

MODULE      := singboxcore
OUT_DIR     := build
LIB_NAME    := lib$(MODULE).dylib

GOOS        ?= darwin
GOARCH      ?= $(shell go env GOARCH)
ifeq ($(ARCH),amd64)
  GOARCH := amd64
endif
ifeq ($(ARCH),arm64)
  GOARCH := arm64
endif

# Prefer a reachable module proxy in CN networks; override as needed.
export GOPROXY ?= https://goproxy.cn,direct

CGO_ENABLED ?= 1
# Match upstream sing-box defaults so Clash API / common protocols work.
TAGS ?= with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,with_clash_api,with_tailscale
# Keep dylib loadable from any path (app Frameworks).
DYLIB_INSTALL_NAME := @rpath/$(LIB_NAME)

.PHONY: all arm64 amd64 universal clean headers check install_name

all: $(OUT_DIR)/$(GOARCH)/$(LIB_NAME)

$(OUT_DIR)/$(GOARCH)/$(LIB_NAME): $(wildcard *.go) $(wildcard dnsgroup/*.go) go.mod go.sum
	@mkdir -p $(OUT_DIR)/$(GOARCH)
	CGO_ENABLED=$(CGO_ENABLED) GOOS=$(GOOS) GOARCH=$(GOARCH) \
		go build -tags "$(TAGS)" -buildmode=c-shared \
		-o $@ \
		-ldflags "-s -w" \
		.
	install_name_tool -id $(DYLIB_INSTALL_NAME) $@
	@cp include/singboxcore.h $(OUT_DIR)/$(GOARCH)/$(MODULE).h
	@echo "Built $@ (id=$(DYLIB_INSTALL_NAME))"

arm64:
	$(MAKE) ARCH=arm64

amd64:
	$(MAKE) ARCH=amd64

universal: arm64 amd64
	@mkdir -p $(OUT_DIR)/universal
	lipo -create \
		$(OUT_DIR)/arm64/$(LIB_NAME) \
		$(OUT_DIR)/amd64/$(LIB_NAME) \
		-output $(OUT_DIR)/universal/$(LIB_NAME)
	install_name_tool -id $(DYLIB_INSTALL_NAME) $(OUT_DIR)/universal/$(LIB_NAME)
	@cp include/singboxcore.h $(OUT_DIR)/universal/$(MODULE).h
	@echo "Built $(OUT_DIR)/universal/$(LIB_NAME)"

headers:
	@mkdir -p $(OUT_DIR)
	@cp include/singboxcore.h $(OUT_DIR)/$(MODULE).h

check:
	go test ./...
	go vet ./...

clean:
	rm -rf $(OUT_DIR)
