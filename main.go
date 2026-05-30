package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	tunnelName  = "wg-netip"
	runtimeName = "/var/run/wireguard/wg-netip.name"
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
	case "stats":
		cmdStats()
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
  netip-spn stats                Print connection stats as JSON (since/rx/tx)
  netip-spn config [path]        Set config file (opens file picker if path omitted)
  netip-spn version              Print version

Config:
  User config directory:  ~/.cloudnetip/
  Config file:            ~/.cloudnetip/spn.conf
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

func userWgConfigPath() string {
	return filepath.Join(userConfigDir(), "wg-netip.conf")
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

// cmdStats prints a one-line JSON object with connection time, interface,
// and rx/tx byte counters. Designed for the menubar app to poll cheaply.
func cmdStats() {
	info, err := os.Stat(runtimeName)
	if err != nil {
		fmt.Println(`{"connected":false}`)
		return
	}
	utun := ""
	if data, err := os.ReadFile(runtimeName); err == nil {
		utun = strings.TrimSpace(string(data))
	}
	if utun == "" {
		utun = findWGUtun()
	}

	since := info.ModTime().Unix()
	rx, tx := readIfaceCounters(utun)
	fmt.Printf(`{"connected":true,"iface":%q,"since":%d,"rx":%d,"tx":%d}`+"\n",
		utun, since, rx, tx)
}

// readIfaceCounters parses `netstat -ibn` to get RX/TX bytes for the given
// interface. macOS-only. Returns 0,0 if the interface is missing or netstat
// fails — never errors, since stats are advisory.
func readIfaceCounters(iface string) (uint64, uint64) {
	if iface == "" {
		return 0, 0
	}
	out, err := exec.Command("netstat", "-ibn").Output()
	if err != nil {
		return 0, 0
	}
	// On macOS netstat -ibn emits two row shapes:
	//   link-level (10 cols): Name Mtu Network=<Link#N> Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
	//   address-level (11 cols): Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
	// The address-level row only counts packets on that family, so the
	// link-level row is the source of truth — sum is the per-iface total.
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 10 || fields[0] != iface {
			continue
		}
		// Link-level rows have "<Link#N>" in the Network column and no Address.
		if strings.HasPrefix(fields[2], "<Link#") {
			rx, _ := strconv.ParseUint(fields[5], 10, 64)
			tx, _ := strconv.ParseUint(fields[8], 10, 64)
			return rx, tx
		}
	}
	return 0, 0
}

// findWGUtun returns the utun interface that WireGuard's userspace daemon is
// bound to. It reads /var/run/wireguard/ — the directory is world-readable on
// macOS even though the .name file inside is root-only. Each running tunnel
// leaves a utunN.sock socket there, so the .sock filename gives us the iface.
func findWGUtun() string {
	entries, err := os.ReadDir("/var/run/wireguard")
	if err != nil {
		return ""
	}
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, "utun") && strings.HasSuffix(name, ".sock") {
			return strings.TrimSuffix(name, ".sock")
		}
	}
	return ""
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

	// Read user config and inject DNS hooks if DNS is present
	configData, err := os.ReadFile(src)
	if err != nil {
		fail("cannot read config: %v", err)
	}
	patchedConfig := injectDNSHooks(string(configData))

	// Write patched config to user directory
	wgConfPath := userWgConfigPath()
	dir := userConfigDir()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		fail("cannot create directory %s: %v", dir, err)
	}

	fmt.Println("Deploying config to", wgConfPath)
	if err := os.WriteFile(wgConfPath, []byte(patchedConfig), 0600); err != nil {
		fail("cannot write config: %v", err)
	}

	fmt.Println("Starting tunnel...")
	mustSudo("wg-quick", "up", wgConfPath)
	fmt.Println("● SPN: connected")
}

func cmdDisconnect() {
	if _, err := os.Stat(runtimeName); err != nil {
		fmt.Println("SPN is already down.")
		return
	}
	requireWireGuard()
	wgConfPath := userWgConfigPath()
	mustSudo("wg-quick", "down", wgConfPath)
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

// injectDNSHooks parses the WireGuard config and injects PostUp/PreDown hooks
// to set DNS via /etc/resolver/ (macOS split DNS), ensuring DNS works reliably.
func injectDNSHooks(config string) string {
	lines := strings.Split(config, "\n")
	var result []string
	var dnsServers []string
	var searchDomains []string
	inInterface := false
	hasPostUp := false
	hasPreDown := false

	for _, line := range lines {
		trimmed := strings.TrimSpace(line)

		// Track [Interface] section
		if strings.HasPrefix(trimmed, "[Interface]") {
			inInterface = true
			result = append(result, line)
			continue
		}
		if strings.HasPrefix(trimmed, "[") {
			inInterface = false
		}

		// Extract DNS servers from Interface section
		if inInterface && strings.HasPrefix(trimmed, "DNS") {
			parts := strings.SplitN(trimmed, "=", 2)
			if len(parts) == 2 {
				dns := strings.TrimSpace(parts[1])
				// Handle comma-separated DNS
				for _, d := range strings.Split(dns, ",") {
					d = strings.TrimSpace(d)
					if d != "" {
						dnsServers = append(dnsServers, d)
					}
				}
			}
		}

		// Check if PostUp/PreDown already exist
		if strings.HasPrefix(trimmed, "PostUp") {
			hasPostUp = true
		}
		if strings.HasPrefix(trimmed, "PreDown") {
			hasPreDown = true
		}

		result = append(result, line)
	}

	// If DNS is present and no custom hooks, inject /etc/resolver/-based DNS
	if len(dnsServers) > 0 && !hasPostUp && !hasPreDown {
		// Detect search domains from config or use common internal TLDs
		if len(searchDomains) == 0 {
			// Default internal domains that should use the VPN DNS
			searchDomains = []string{"netip", "internal", "local"}
		}

		// Find the end of [Interface] section to inject hooks
		for i, line := range result {
			trimmed := strings.TrimSpace(line)
			if strings.HasPrefix(trimmed, "[Interface]") {
				// Find where to insert
				insertAt := i + 1
				for j := i + 1; j < len(result); j++ {
					t := strings.TrimSpace(result[j])
					if strings.HasPrefix(t, "[") {
						break
					}
					if t != "" && !strings.HasPrefix(t, "#") {
						insertAt = j + 1
					}
				}

				var hooks []string
				// Create resolver files for each search domain
				for _, domain := range searchDomains {
					resolverFile := fmt.Sprintf("/etc/resolver/%s", domain)
					// PostUp: create resolver file
					postUp := fmt.Sprintf("mkdir -p /etc/resolver && printf 'nameserver %s\\n' > %s",
						dnsServers[0], resolverFile)
					hooks = append(hooks, fmt.Sprintf("PostUp = %s", postUp))
				}

				// PreDown: remove resolver files
				for _, domain := range searchDomains {
					resolverFile := fmt.Sprintf("/etc/resolver/%s", domain)
					hooks = append(hooks, fmt.Sprintf("PreDown = rm -f %s", resolverFile))
				}

				// Insert hooks
				result = append(result[:insertAt], append(hooks, result[insertAt:]...)...)
				break
			}
		}
	}

	return strings.Join(result, "\n")
}
