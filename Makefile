BINARY := netip-spn
VERSION ?= dev
LDFLAGS := -s -w -X main.version=$(VERSION)

.PHONY: build build-linux build-darwin install clean test run app app-dev app-clean package release release-assets all dev dev-cli dev-app dev-clean

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

# ---- Local dev: build current CLI + GUI and launch them for testing ----

# Install freshly built CLI to /usr/local/bin (GUI ищет его там через locateCLI).
# GUI's locateCLI() checks /opt/homebrew/bin first, so we unlink the brew copy
# while the dev build is active — otherwise the brew symlink wins and the GUI
# shows the old version. `make dev-clean` relinks it.
dev-cli: build
	@echo "==> unlinking brew copy of $(BINARY) (if present) so dev build wins"
	-brew unlink cloudnetip-spn >/dev/null 2>&1 || true
	@echo "==> installing $(BINARY) to /usr/local/bin (sudo)"
	sudo install -m 0755 $(BINARY) /usr/local/bin/$(BINARY)
	@echo "==> $$(/usr/local/bin/$(BINARY) version 2>/dev/null || echo installed)"

# Build native-arch .app and launch it (kills previous instance first).
dev-app: app-dev
	@echo "==> relaunching Cloudnetip SPN.app"
	-pkill -x CloudnetipSPN 2>/dev/null || true
	open "gui/build/Cloudnetip SPN.app"

# Remove dev artifacts so brew install works cleanly afterwards.
# Disconnects the tunnel if up, quits the GUI, deletes the locally-installed
# CLI from /usr/local/bin and the dev .app from gui/build, and clears local
# build outputs. Leaves brew-managed installs (/opt/homebrew/...) untouched.
dev-clean:
	@echo "==> stopping tunnel + GUI"
	-/usr/local/bin/$(BINARY) disconnect 2>/dev/null || true
	-pkill -x CloudnetipSPN 2>/dev/null || true
	@echo "==> removing dev CLI from /usr/local/bin (sudo)"
	-sudo rm -f /usr/local/bin/$(BINARY)
	@echo "==> relinking brew copy of $(BINARY) (if installed)"
	-brew link --overwrite cloudnetip-spn >/dev/null 2>&1 || true
	@echo "==> removing dev .app and build outputs"
	rm -rf "gui/build/Cloudnetip SPN.app" gui/.build $(BINARY) dist
	@echo "==> done. Brew install restored (if it was present)."

# One-shot: rebuild CLI + GUI, install CLI, relaunch GUI.
dev: dev-cli dev-app
	@echo
	@echo "==> ready. CLI:  /usr/local/bin/$(BINARY)"
	@echo "          GUI:  gui/build/Cloudnetip SPN.app (running)"
	@echo "    Logs (CLI): netip-spn status / netip-spn connect"
	@echo "    Logs (GUI): log stream --predicate 'process == \"CloudnetipSPN\"' --level debug"
