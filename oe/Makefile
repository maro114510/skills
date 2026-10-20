BINARY := oe
VERSION := $(shell git describe --tags --match 'oe-v*' --always --dirty 2>/dev/null || echo v0.0.0-dev)
LDFLAGS := -s -w -X main.version=$(VERSION)

export CGO_ENABLED := 0
export GOFLAGS := -mod=readonly

.DEFAULT_GOAL := help

# The release matrix, with assets named oe_<os>_<arch>.
# skills/orchestrate-epic/scripts/oe and bin/oe-manifest.sh rely on that exact shape.
PLATFORMS := darwin/arm64 darwin/amd64 linux/arm64 linux/amd64
DIST := dist

.PHONY: build dist test vet fmt lint tidy clean help

build: ## Build the binary without cgo
	go build -ldflags "$(LDFLAGS)" -o $(BINARY) .

dist: ## Build the release assets and SHA256SUMS into dist/ for VERSION=oe-vX.Y.Z
	@printf '%s\n' "$(VERSION)" | grep -Eq '^oe-v[0-9]+\.[0-9]+\.[0-9]+$$' || { printf 'dist needs VERSION=oe-vX.Y.Z, got %s\n' "$(VERSION)" >&2; exit 1; }
	rm -rf $(DIST)
	mkdir -p $(DIST)
	@set -e; for platform in $(PLATFORMS); do \
		os="$${platform%/*}"; arch="$${platform#*/}"; \
		echo "build $(DIST)/$(BINARY)_$${os}_$${arch}"; \
		GOOS="$$os" GOARCH="$$arch" go build -trimpath -ldflags "$(LDFLAGS)" -o "$(DIST)/$(BINARY)_$${os}_$${arch}" .; \
	done
	cd $(DIST) && { sha256sum $(BINARY)_* 2>/dev/null || shasum -a 256 $(BINARY)_*; } > SHA256SUMS

test: ## Run the tests
	go test ./...

vet: ## Run go vet
	go vet ./...

fmt: ## Check formatting with gofmt
	@test -z "$$(gofmt -l main.go cmd internal)" || (gofmt -l main.go cmd internal && exit 1)

lint: ## Run golangci-lint
	golangci-lint run

tidy: ## Tidy go.mod and go.sum, then verify module checksums
	GOFLAGS= go mod tidy && go mod verify

clean: ## Remove build artifacts
	rm -f $(BINARY)
	rm -rf $(DIST)

help: ## Show this help message
	@awk 'BEGIN {FS = ":.*##"; printf "Usage:\n  make <target>\n\nTargets:\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  %-10s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
