# Cloudnetip SPN

CLI and macOS menubar app to bring the Cloudnetip Shared Private Network up and down.

- **CLI** (`netip-spn`) — Go, runs on **macOS** and **Linux**.
- **GUI** (`Cloudnetip SPN.app`) — SwiftUI menubar app, **macOS only**. Shells out to the CLI; no duplicated logic.

## Install

### macOS

```bash
brew tap cloudnetip/tap
brew install cloudnetip-spn          # CLI only
brew install --cask cloudnetip-spn   # GUI + CLI (the cask depends on the formula)
```

The cask is the recommended install: you get `Cloudnetip SPN.app` in `/Applications` plus the `netip-spn` command in your PATH, ready to go.

The .app is ad-hoc signed and shipped through brew, so Gatekeeper does not flag it. No Apple Developer account required.

### Linux — CLI from source

```bash
sudo apt install wireguard-tools zenity   # or your distro's equivalent
git clone https://github.com/cloudnetip/netip-spn.git
cd netip-spn
make build && sudo make install
```

The GUI is macOS-only by design. On Linux, use the CLI directly or wrap it in a `.desktop` launcher.

## Usage

```bash
netip-spn config ~/Downloads/spn.conf   # save your WireGuard config
netip-spn config                         # …or open a native file picker
netip-spn connect                        # bring tunnel up (asks for sudo)
netip-spn status                         # check state (no sudo needed)
netip-spn disconnect                     # bring tunnel down
```

The menubar app provides the same actions plus auto-refreshing status. Connect/Disconnect launch a Terminal window so you can enter your sudo password.

## Where files live

| Path                                | Purpose                                  |
|-------------------------------------|------------------------------------------|
| `~/.cloudnetip/spn.conf`            | Your saved WireGuard config (mode 600)   |
| `~/.cloudnetip/wg-netip.conf`       | Deployed copy used by `wg-quick`         |
| `/var/run/wireguard/wg-netip.name`  | Created by wg-quick when tunnel is up    |

`netip-spn config` validates the file has an `[Interface]` section and copies it into `~/.cloudnetip/`. Every `connect` re-deploys the saved config to `~/.cloudnetip/wg-netip.conf`, so editing `~/.cloudnetip/spn.conf` is enough — no need to re-run `config`.

## Build

```bash
make build              # CLI for current platform
make build-darwin       # CLI for darwin/{arm64,amd64} into dist/
make build-linux        # CLI for linux/{arm64,amd64} into dist/
make app                # universal arm64+x86_64 Cloudnetip SPN.app
make app-dev            # native-arch only (faster iteration)
make package            # builds the .app and zips it for the cask, prints sha256
make release-assets     # everything needed for a release
```

## Repository layout

```
.
├── main.go                       CLI entry
├── picker_darwin.go              osascript file picker
├── picker_linux.go               zenity/kdialog file picker
├── go.mod
├── Makefile
├── gui/                          SwiftUI menubar app
│   ├── Package.swift
│   ├── Sources/CloudnetipSPN/
│   ├── Resources/Info.plist
│   └── build-app.sh              wraps the executable into .app bundle, ad-hoc signs
├── Formula/                      Reference formula — copy into the tap repo
│   └── cloudnetip-spn.rb
└── Casks/                        Reference cask — copy into the tap repo
    └── cloudnetip-spn.rb
```

## Publishing to Homebrew

You need two GitHub repos under the `cloudnetip` org:

1. **`github.com/cloudnetip/netip-spn`** — this repository (source)
2. **`github.com/cloudnetip/homebrew-tap`** — the tap (Homebrew requires the `homebrew-` prefix; the tap is then referenced as `cloudnetip/tap`). One tap holds all Cloudnetip formulas/casks (cloudnetip-spn now, more later).

### One-time setup

Create the tap repo on GitHub: **`github.com/cloudnetip/homebrew-tap`**. Initialize it empty — the release script will populate it on the first run.

By default the script clones the tap into `<repo>/.tap/homebrew-tap` (gitignored), so you don't need to manage a separate sibling directory. To use a different location, set `TAP_REPO=/path/to/clone`.

### Cutting a release

```bash
make release VERSION=0.1.0
```

That's it. The script does everything:
- Builds the universal .app and zips it
- Tags and pushes `v0.1.0`
- Creates a GitHub Release with the .app zip attached
- Computes sha256 of the source tarball and .app zip
- Patches `Formula/cloudnetip-spn.rb` and `Casks/cloudnetip-spn.rb` with the new version + sha256s
- Commits and pushes the patched files to this repo
- Clones (or pulls) the tap into `.tap/homebrew-tap` (gitignored), copies the formulas, commits and pushes

**Dry run** (prints actions without pushing):
```bash
make release VERSION=0.1.0 DRY_RUN=1
```

**Manual invocation** (if you prefer):
```bash
./scripts/brew-release v0.1.0
```

### Verify the release

```bash
brew untap cloudnetip/tap 2>/dev/null
brew tap cloudnetip/tap
brew install --cask cloudnetip-spn
```

The cask installs both the GUI (`Cloudnetip SPN.app` in `/Applications`) and the CLI (`netip-spn` in your PATH).

## Why no Apple Developer cert is needed

- **CLI**: the formula builds Go code from source on the user's machine. Locally-built binaries have no `com.apple.quarantine` attribute, so Gatekeeper does not check them.
- **GUI**: `build-app.sh` builds a universal binary and ad-hoc signs it (`codesign --force --deep --sign -`). Apple Silicon requires *some* signature for executables to launch; ad-hoc satisfies that without a paid certificate. Brew installs the .app via cask, which strips the quarantine attribute on its way to `/Applications`.

## License

MIT — see [LICENSE](LICENSE).
