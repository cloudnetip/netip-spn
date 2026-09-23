# Cloudnetip SPN

CLI and macOS menubar app to bring the Cloudnetip Shared Private Network up and down.

- **CLI** (`netip-spn`) — Go, runs on **macOS** and **Linux**.
- **GUI** (`Cloudnetip SPN.app`) — SwiftUI menubar app, **macOS only**. Uses the CLI for account/config/status work and
  a bundled WireGuard runtime for tunnel operations.

## Install

### macOS

```bash
brew tap cloudnetip/tap
brew install cloudnetip-spn          # CLI only
brew install --cask cloudnetip-spn   # GUI + CLI (the cask depends on the formula)
```

The cask is the recommended install: you get `Cloudnetip SPN.app` in `/Applications` plus the `netip-spn` command in
your PATH, ready to go. On macOS the persistent SPN config is stored as a root-owned file under
`/Library/Application Support/Cloudnetip SPN/`; changing or removing it requires administrator authorization.

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
netip-spn connect                        # CLI tunnel via Homebrew/system wg-quick (sudo)
netip-spn status                         # check state (no sudo needed)
netip-spn disconnect                     # CLI tunnel down via wg-quick (sudo)
netip-spn sudoers                        # install/update the GUI privileged runtime manually
netip-spn sudoers check                  # show GUI helper/runtime state
netip-spn sudoers remove                 # remove the GUI helper/runtime
```

The menubar app has its own pinned WireGuard runtime. On the first Connect it asks for macOS administrator
authorization once and copies the bundled `wg` and `wireguard-go` binaries together with the root-owned helper into
`/Library/PrivilegedHelperTools/cloudnetip-spn/`. Future Connect/Disconnect actions use only that root-owned runtime
through the tightly scoped sudoers rule and do not ask for a password again.

The GUI does not use `wg-quick`. The helper creates the macOS `utun` with `wireguard-go`, applies the WireGuard config
with the bundled `wg`, configures addresses/MTU/routes with macOS system tools, and publishes/removes the VPN DNS entry
through `scutil`. Homebrew `wireguard-tools` remains a dependency of the CLI formula only. The cask still depends on the
formula because the GUI uses `netip-spn` for auth/config/status operations.

The privileged runtime has an independent pinned runtime ID defined by `wireguard-runtime.conf`. Normal GUI/CLI app
updates do not touch it. If `wg` or `wireguard-go` is intentionally bumped, the new app detects the runtime mismatch
and asks for administrator authorization once on the next Connect to replace the root-owned runtime. During that
one-time privileged upgrade, an existing `~/.cloudnetip/spn.conf` is migrated into the root-owned macOS config location
and the legacy `~/.cloudnetip` directory is removed. The GUI moves the old `wireguard.log` to
`~/Library/Logs/Cloudnetip SPN/` before that migration. `Show stats in bar` is off by default; when enabled, the two
menubar rates refresh once per second. `Show logs` opens captured tunnel logs.

## Where files live

| Path                                                            | Purpose                                              |
|-----------------------------------------------------------------|------------------------------------------------------|
| `/Library/Application Support/Cloudnetip SPN/spn.conf`          | Root-owned persistent SPN config on macOS (mode 600) |
| `~/Library/Logs/Cloudnetip SPN/wireguard.log`                   | GUI-captured connect/disconnect log (mode 600)       |
| `/Library/PrivilegedHelperTools/cloudnetip-spn/helper`          | Root-owned GUI networking helper                     |
| `/Library/PrivilegedHelperTools/cloudnetip-spn/wg`              | Root-owned bundled `wg` used only by the GUI         |
| `/Library/PrivilegedHelperTools/cloudnetip-spn/wireguard-go`    | Root-owned bundled userspace WireGuard engine        |
| `/Library/PrivilegedHelperTools/cloudnetip-spn/runtime.version` | Installed GUI WireGuard runtime ID                   |
| `/var/run/netip-spn/wg-netip.conf`                              | Root-owned `wg setconf` payload while connected      |
| `/var/run/netip-spn/state.json`                                 | Routes/interface state created by the GUI helper     |
| `/var/run/wireguard/wg-netip.name`                              | Actual `utun` selected by bundled `wireguard-go`     |

On macOS, `netip-spn config` and `netip-spn auth login` validate the WireGuard config and then request administrator
authorization to replace the root-owned persistent config atomically. The GUI helper reads only that fixed root-owned
config path; no user-writable config path is accepted by the passwordless helper. Linux keeps the existing per-user
`~/.cloudnetip/spn.conf` layout. The CLI keeps its traditional `wg-quick` path; its temporary privileged config strips
user shell hooks before execution.

### GUI privileged runtime

The GUI sudoers rule never grants `NOPASSWD` to Homebrew `wg`, `wg-quick`, a shell, or an arbitrary executable. It
allows only the root-owned helper's exact internal `check`, `up`, and `down` operations, with no path arguments at all.
The helper always reads `/Library/Application Support/Cloudnetip SPN/spn.conf`, which is owned by root and mode 600. The
helper itself can execute only the root-owned `wg` and `wireguard-go` copied from the application bundle during an
administrator-authorized install/update.

The GUI networking path intentionally does not use user-supplied `PreUp`, `PostUp`, `PreDown`, `PostDown`, or
`SaveConfig`. `Address`, `DNS`, `MTU`, and `Table` are parsed by the helper and applied directly; the remaining
WireGuard
keys are sent to `wg setconf`. This keeps passwordless root execution away from arbitrary config shell hooks.

The CLI stays conventional: `netip-spn connect/disconnect` uses the `wireguard-tools` installation supplied by the
platform/Homebrew and requests sudo normally. The bundled runtime is a GUI implementation detail.

## Build

```bash
make build              # CLI for current platform
make build-darwin       # CLI for darwin/{arm64,amd64} into dist/
make build-linux        # CLI for linux/{arm64,amd64} into dist/
make wireguard-runtime  # build the pinned universal GUI wg + wireguard-go runtime
make app                # universal app, including the pinned WireGuard runtime
make app-dev            # native-arch only (faster iteration)
make package            # builds the .app and zips it for the cask, prints sha256
make release-assets     # everything needed for a release
```

## Local development

Build the current source as both CLI and GUI and run them against your real
config — no brew round-trip required.

```bash
make dev-cli   # builds the CLI and installs it to /usr/local/bin/netip-spn (sudo)
make dev-app   # builds the native-arch .app, kills any running instance, opens the fresh one
make dev       # both: rebuild CLI + GUI, reinstall, relaunch
```

The GUI locates the CLI via `locateCLI()` and checks `/opt/homebrew/bin`,
`/usr/local/bin`, `/usr/bin` in that order. To make the dev build win,
`make dev-cli` runs `brew unlink cloudnetip-spn` (no-op if not installed)
and then installs the dev binary to `/usr/local/bin/netip-spn`.
`make dev-clean` reverses both steps with `brew link --overwrite`.

If the GUI still shows the brew version in its menu, restart the .app
(`make dev-app` does this) — `locateCLI()` is called per launch.

### GUI OSX logs:

```bash
log stream --predicate 'process == "CloudnetipSPN"' --level debug
```

### Going back to brew

```bash
make dev-clean   # disconnect, quit GUI, remove dev CLI + .app + build outputs
brew install --cask cloudnetip/tap/cloudnetip-spn
```

`dev-clean` does not touch anything under `/opt/homebrew` or `/Applications` —
only the dev artifacts this Makefile created.

## Publishing to Homebrew

You need two GitHub repos under the `cloudnetip` org:

1. **`github.com/cloudnetip/netip-spn`** — this repository (source)
2. **`github.com/cloudnetip/homebrew-tap`** — the tap (Homebrew requires the `homebrew-` prefix; the tap is then
   referenced as `cloudnetip/tap`). One tap holds all Cloudnetip formulas/casks (cloudnetip-spn now, more later).

### One-time setup

Create the tap repo on GitHub: **`github.com/cloudnetip/homebrew-tap`**. Initialize it empty — the release script will
populate it on the first run.

By default the script clones the tap into `<repo>/.tap/homebrew-tap` (gitignored), so you don't need to manage a
separate sibling directory. To use a different location, set `TAP_REPO=/path/to/clone`.

### Cutting a release

```bash
make release VERSION=0.1.0
```

That's it. The script does everything:

- Builds the pinned universal WireGuard GUI runtime, then the universal .app and zip
- Tags and pushes `v0.1.0`
- Creates a GitHub Release with the .app zip attached
- Computes sha256 of the source tarball and .app zip
- Patches `Formula/cloudnetip-spn.rb` and `Casks/cloudnetip-spn.rb` with the new version + sha256s
- Keeps the WireGuard runtime version unchanged unless `wireguard-runtime.conf` was explicitly bumped
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

- **CLI**: the formula builds Go code from source on the user's machine. Locally-built binaries have no
  `com.apple.quarantine` attribute, so Gatekeeper does not check them.
- **GUI**: `build-app.sh` builds a universal binary and ad-hoc signs it (`codesign --force --deep --sign -`). Apple
  Silicon requires *some* signature for executables to launch; ad-hoc satisfies that without a paid certificate. Brew
  installs the .app via cask, which strips the quarantine attribute on its way to `/Applications`.

## License

MIT — see [LICENSE](LICENSE).
