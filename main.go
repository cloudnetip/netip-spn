package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const (
	tunnelName     = "wg-netip"
	systemConfPath = "/etc/wireguard/wg-netip.conf"
	runtimeName    = "/var/run/wireguard/wg-netip.name"
)

var version = "dev"

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(2)
	}

	switch os.Args[1] {
	case "status":
		cmdStatus()
	case "connect", "up":
		cmdConnect()
	case "disconnect", "down":
		cmdDisconnect()
	case "config":
		var path string
		if len(os.Args) >= 3 {
			path = os.Args[2]
		}
		cmdConfig(path)
	case "version", "--version", "-v":
		fmt.Println("netip-spn", version)
	case "help", "--help", "-h":
		printUsage()
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n\n", os.Args[1])
		printUsage()
		os.Exit(2)
	}
}

func printUsage() {
	fmt.Print(`netip-spn — Cloudnetip Shared Private Network CLI

Usage:
  netip-spn connect              Bring SPN tunnel up
  netip-spn disconnect           Bring SPN tunnel down
  netip-spn status               Show tunnel state
  netip-spn config [path]        Set config file (opens file picker if path omitted)
  netip-spn version              Print version

Config:
  Default user config:    ~/.cloudnetip/spn.conf
  Deployed system path:   ` + systemConfPath + `
  Tunnel interface name:  ` + tunnelName + `

Requires: wireguard-tools (brew install wireguard-tools)
`)
}

func userConfigDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		fail("cannot resolve home directory: %v", err)
	}
	return filepath.Join(home, ".cloudnetip")
}

func userConfigPath() string {
	return filepath.Join(userConfigDir(), "spn.conf")
}

func cmdStatus() {
	if _, err := os.Stat(runtimeName); err != nil {
		fmt.Println("● SPN: disconnected")
		return
	}
	data, err := os.ReadFile(runtimeName)
	if err != nil {
		fmt.Println("● SPN: connected")
		return
	}
	utun := strings.TrimSpace(string(data))
	fmt.Printf("● SPN: connected (%s → %s)\n", tunnelName, utun)
	fmt.Println()
	fmt.Println("For peer details run: sudo wg show", tunnelName)
}

func cmdConnect() {
	requireWireGuard()

	src := userConfigPath()
	if _, err := os.Stat(src); err != nil {
		fail("no config found at %s\n   Run: netip-spn config <path-to-spn.conf>", src)
	}

	if _, err := os.Stat(runtimeName); err == nil {
		fmt.Println("SPN is already up. Run `netip-spn disconnect` first.")
		return
	}

	fmt.Println("Deploying config to", systemConfPath)
	mustSudo("install", "-d", "-m", "700", "/etc/wireguard")
	mustSudo("install", "-m", "600", src, systemConfPath)

	fmt.Println("Starting tunnel...")
	mustSudo("wg-quick", "up", tunnelName)
	fmt.Println("● SPN: connected")
}

func cmdDisconnect() {
	if _, err := os.Stat(runtimeName); err != nil {
		fmt.Println("SPN is already down.")
		return
	}
	requireWireGuard()
	mustSudo("wg-quick", "down", tunnelName)
	fmt.Println("● SPN: disconnected")
}

func cmdConfig(path string) {
	if path == "" {
		picked, err := pickFile()
		if err != nil {
			fail("file picker failed: %v", err)
		}
		if picked == "" {
			fmt.Println("Cancelled.")
			return
		}
		path = picked
	}

	abs, err := filepath.Abs(expandHome(path))
	if err != nil {
		fail("bad path: %v", err)
	}
	if _, err := os.Stat(abs); err != nil {
		fail("file not found: %s", abs)
	}

	data, err := os.ReadFile(abs)
	if err != nil {
		fail("cannot read %s: %v", abs, err)
	}
	if !looksLikeWireGuardConfig(data) {
		fail("file does not look like a WireGuard config (missing [Interface] section): %s", abs)
	}

	dir := userConfigDir()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		fail("cannot create %s: %v", dir, err)
	}
	dst := userConfigPath()
	if err := os.WriteFile(dst, data, 0o600); err != nil {
		fail("cannot write %s: %v", dst, err)
	}
	fmt.Printf("Config saved to %s\n", dst)
	fmt.Println("Now run: netip-spn connect")
}

func looksLikeWireGuardConfig(data []byte) bool {
	return strings.Contains(string(data), "[Interface]")
}

func expandHome(p string) string {
	if strings.HasPrefix(p, "~") {
		home, err := os.UserHomeDir()
		if err == nil {
			return filepath.Join(home, strings.TrimPrefix(p, "~"))
		}
	}
	return p
}

func requireWireGuard() {
	if _, err := exec.LookPath("wg-quick"); err != nil {
		fail("wg-quick not found. " + installHint())
	}
}

func mustSudo(args ...string) {
	cmd := exec.Command("sudo", args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fail("command failed: sudo %s: %v", strings.Join(args, " "), err)
	}
}

func fail(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "✗ "+format+"\n", a...)
	os.Exit(1)
}
