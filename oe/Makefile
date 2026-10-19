BINARY := oe
VERSION := $(shell git describe --tags --match 'oe-v*' --always --dirty 2>/dev/null || echo v0.0.0-dev)
LDFLAGS := -s -w -X main.version=$(VERSION)

export CGO_ENABLED := 0
export GOFLAGS := -mod=readonly

.DEFAULT_GOAL := help

.PHONY: build test vet fmt lint tidy clean help

build: ## Build the binary without cgo
	go build -ldflags "$(LDFLAGS)" -o $(BINARY) .

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

help: ## Show this help message
	@awk 'BEGIN {FS = ":.*##"; printf "Usage:\n  make <target>\n\nTargets:\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  %-10s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
