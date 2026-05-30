BINARY := netip-spn
VERSION ?= dev
LDFLAGS := -s -w -X main.version=$(VERSION)

.PHONY: build build-linux build-darwin install clean test run app app-dev app-clean package release release-assets all

build:
	go build -ldflags "$(LDFLAGS)" -o $(BINARY) .

build-darwin:
	GOOS=darwin GOARCH=arm64 go build -ldflags "$(LDFLAGS)" -o dist/$(BINARY)-darwin-arm64 .
	GOOS=darwin GOARCH=amd64 go build -ldflags "$(LDFLAGS)" -o dist/$(BINARY)-darwin-amd64 .

build-linux:
	GOOS=linux GOARCH=arm64 go build -ldflags "$(LDFLAGS)" -o dist/$(BINARY)-linux-arm64 .
	GOOS=linux GOARCH=amd64 go build -ldflags "$(LDFLAGS)" -o dist/$(BINARY)-linux-amd64 .

install: build
	install -m 0755 $(BINARY) /usr/local/bin/$(BINARY)

clean:
	rm -f $(BINARY)
	rm -rf dist

test:
	go vet ./...
	go test ./...

run:
	go run .

# Universal arm64+x86_64 .app — used for release/cask packaging.
app:
	cd gui && ./build-app.sh $(VERSION) build

# Native-arch .app — faster local iteration.
app-dev:
	cd gui && UNIVERSAL=0 ./build-app.sh $(VERSION) build

app-clean:
	rm -rf gui/.build gui/build

# Zip the .app for upload to GitHub Releases (consumed by the Cask).
package: app
	mkdir -p dist
	cd gui/build && /usr/bin/ditto -c -k --keepParent "Cloudnetip SPN.app" ../../dist/Cloudnetip-SPN-$(VERSION).zip
	@echo
	@echo "==> dist/Cloudnetip-SPN-$(VERSION).zip"
	@echo "    sha256: $$(shasum -a 256 dist/Cloudnetip-SPN-$(VERSION).zip | awk '{print $$1}')"

# Everything needed to cut a release: cross-compiled CLIs + universal .app .zip.
release-assets: build-darwin build-linux package

# Cut a release end-to-end: build, tag, push, GitHub release, update tap.
# Usage: make release VERSION=0.1.0
release:
	@case "$(VERSION)" in \
		[0-9]*.[0-9]*.[0-9]*) ;; \
		*) echo "Usage: make release VERSION=X.Y.Z (got: '$(VERSION)')"; exit 2 ;; \
	esac
	./scripts/brew-release "v$(VERSION)"

all: build build-darwin build-linux app
