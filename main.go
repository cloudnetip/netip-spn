package main

import (
	"fmt"
	"net"
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
	case "auth":
		cmdAuth(os.Args[2:])
	case "sudoers":
		cmdSudoers(os.Args[2:])
	case "_sudoers-install":
		cmdSudoersRootInstall(os.Args[2:])
	case "_sudoers-remove":
		cmdSudoersRootRemove()
	case "_privileged":
		cmdPrivileged(os.Args[2:])
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
  netip-spn auth login           Sign in via browser, choose SPN, save config
  netip-spn auth logout          Remove saved config
  netip-spn connect              Bring SPN tunnel up
  netip-spn disconnect           Bring SPN tunnel down
  netip-spn status               Show tunnel state
  netip-spn stats                Print connection stats as JSON (since/rx/tx)
  netip-spn config [path]        Set config file from local path (file picker if omitted)
  netip-spn sudoers              Enable passwordless connect/disconnect (one-time admin auth)
  netip-spn sudoers check        Show passwordless mode state
  netip-spn sudoers remove       Disable passwordless mode
  netip-spn version              Print version

Config:
  User config directory:  ~/.cloudnetip/
  Config file:            ~/.cloudnetip/spn.conf
  Tunnel interface name:  ` + tunnelName + `

Environment:
  NETIP_API_URL                  Override API base URL (dev/staging)

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
		// wireguard-go writes the authoritative utun name to runtimeName, but
		// that file is root-only on macOS. Match the Address from our config to
		// the live utun interface instead of blindly taking the first utun socket.
		utun = findWGUtunByConfig(userConfigPath())
	}
	if utun == "" {
		// Last-resort compatibility fallback for configs without Address.
		utun = findWGUtun()
	}

	since := info.ModTime().Unix()
	rx, tx, ok := readPrivilegedWireGuardCounters(userConfigPath())
	counterSource := "wireguard"
	if !ok {
		// Fallback for older helpers or unusual installations. WireGuard's own
		// transfer counters are preferred because they describe the tunnel
		// itself rather than macOS' utun accounting.
		rx, tx = readIfaceCounters(utun)
		counterSource = "netstat"
	}
	fmt.Printf(`{"connected":true,"iface":%q,"since":%d,"rx":%d,"tx":%d,"source":%q}`+"\n",
		utun, since, rx, tx, counterSource)
}

func readPrivilegedWireGuardCounters(source string) (uint64, uint64, bool) {
	cmd := exec.Command("sudo", "-n", privilegedHelperPath(), "_privileged", "check", source)
	out, err := cmd.Output()
	if err != nil {
		return 0, 0, false
	}
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(strings.TrimSpace(line))
		if len(fields) != 3 || fields[0] != "wireguard-transfer:" {
			continue
		}
		rx, rxErr := strconv.ParseUint(fields[1], 10, 64)
		tx, txErr := strconv.ParseUint(fields[2], 10, 64)
		if rxErr == nil && txErr == nil {
			return rx, tx, true
		}
	}
	return 0, 0, false
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
	return parseIfaceCounters(string(out), iface)
}

func parseIfaceCounters(output, iface string) (uint64, uint64) {
	if iface == "" {
		return 0, 0
	}

	// macOS labels received bytes as Ibytes and transmitted bytes as Obytes.
	// A <Link#N> row may omit the Address field (utun commonly does), which
	// shifts all following columns left by one. Read the header so both shapes
	// are handled instead of assuming one fixed set of indexes.
	headerLen, iBytesCol, oBytesCol := 0, -1, -1
	for _, line := range strings.Split(output, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		if fields[0] == "Name" {
			headerLen = len(fields)
			for i, field := range fields {
				switch field {
				case "Ibytes":
					iBytesCol = i
				case "Obytes":
					oBytesCol = i
				}
			}
			continue
		}
		if len(fields) < 3 || fields[0] != iface || !strings.HasPrefix(fields[2], "<Link#") {
			continue
		}

		rxCol, txCol := iBytesCol, oBytesCol
		if headerLen > 0 && len(fields) == headerLen-1 {
			rxCol--
			txCol--
		}
		if rxCol < 0 || txCol < 0 || rxCol >= len(fields) || txCol >= len(fields) {
			// Fallback for unusual output without a recognizable header.
			if len(fields) >= 11 {
				rxCol, txCol = 6, 9
			} else if len(fields) >= 10 {
				rxCol, txCol = 5, 8
			} else {
				return 0, 0
			}
		}

		rx, rxErr := strconv.ParseUint(fields[rxCol], 10, 64)
		tx, txErr := strconv.ParseUint(fields[txCol], 10, 64)
		if rxErr != nil || txErr != nil {
			return 0, 0
		}
		return rx, tx
	}
	return 0, 0
}

func findWGUtunByConfig(configPath string) string {
	data, err := os.ReadFile(configPath)
	if err != nil {
		return ""
	}
	targets := parseWireGuardInterfaceIPs(string(data))
	if len(targets) == 0 {
		return ""
	}

	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	for _, iface := range ifaces {
		if !strings.HasPrefix(iface.Name, "utun") {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			ip := ipFromInterfaceAddr(addr.String())
			if ip == nil {
				continue
			}
			for _, target := range targets {
				if ip.Equal(target) {
					return iface.Name
				}
			}
		}
	}
	return ""
}

func parseWireGuardInterfaceIPs(config string) []net.IP {
	var result []net.IP
	inInterface := false
	for _, line := range strings.Split(config, "\n") {
		trimmed := strings.TrimSpace(strings.SplitN(line, "#", 2)[0])
		if strings.HasPrefix(trimmed, "[") {
			inInterface = strings.EqualFold(trimmed, "[Interface]")
			continue
		}
		if !inInterface {
			continue
		}
		parts := strings.SplitN(trimmed, "=", 2)
		if len(parts) != 2 || !strings.EqualFold(strings.TrimSpace(parts[0]), "Address") {
			continue
		}
		for _, raw := range strings.Split(parts[1], ",") {
			ip := ipFromInterfaceAddr(strings.TrimSpace(raw))
			if ip != nil {
				result = append(result, ip)
			}
		}
	}
	return result
}

func ipFromInterfaceAddr(value string) net.IP {
	value = strings.TrimSpace(value)
	if value == "" {
		return nil
	}
	if ip, _, err := net.ParseCIDR(value); err == nil {
		return ip
	}
	return net.ParseIP(value)
}

// findWGUtun is a last-resort compatibility fallback. If the WireGuard
// runtime directory is readable, each userspace tunnel leaves a utunN.sock
// there. Do not prefer this over findWGUtunByConfig: multiple WireGuard tunnels
// can coexist and the first socket is not necessarily ours.
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

func cmdAuth(args []string) {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: netip-spn auth <login|logout>")
		os.Exit(2)
	}
	switch args[0] {
	case "login":
		cmdAuthLogin()
	case "logout":
		cmdAuthLogout()
	default:
		fmt.Fprintf(os.Stderr, "unknown auth subcommand: %s\n", args[0])
		os.Exit(2)
	}
}

func cmdConnect() {
	requireWireGuard()

	src := userConfigPath()
	if _, err := os.Stat(src); err != nil {
		fail("no config found at %s\n   Run: netip-spn auth login (or: netip-spn config <path>)", src)
	}
	if _, err := os.Stat(runtimeName); err == nil {
		fmt.Println("SPN is already up. Run `netip-spn disconnect` first.")
		return
	}

	fmt.Println("Starting tunnel...")
	runPrivileged("up", src)
	fmt.Println("● SPN: connected")
}

func cmdDisconnect() {
	if _, err := os.Stat(runtimeName); err != nil {
		fmt.Println("SPN is already down.")
		return
	}
	requireWireGuard()
	src := userConfigPath()
	runPrivileged("down", src)
	fmt.Println("● SPN: disconnected")
}

func runPrivileged(action, source string) {
	var exe string
	var args []string
	if activeNow() {
		exe = privilegedHelperPath()
		args = []string{"-n", exe, "_privileged", action, source}
		exe = "sudo"
	} else {
		current, err := os.Executable()
		if err != nil {
			fail("cannot resolve executable path: %v", err)
		}
		current, _ = filepath.EvalSymlinks(current)
		exe = "sudo"
		args = []string{current, "_privileged", action, source}
	}
	cmd := exec.Command(exe, args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fail("privileged %s failed: %v", action, err)
	}
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
	fmt.Println("Config saved, now run: netip-spn connect")
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

func fail(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "✗ "+format+"\n", a...)
	os.Exit(1)
}

// injectDNSHooks parses the WireGuard config and injects PostUp/PreDown hooks
// that register our DNS in the scutil DynamicStore. This wins over DNS pushed
// by the official WireGuard.app (NEDNSSettings) and adds search domains so
// bare hostnames (e.g. "krl-2") resolve via the VPN DNS.
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

		// Extract DNS servers from Interface section, then DROP the line.
		// Keeping "DNS =" in the config makes wg-quick manage DNS itself via
		// `networksetup -setdnsservers`, which hard-writes our VPN DNS into
		// every network service (Wi-Fi, LAN, ...) on up and "restores" a
		// possibly-stale value on down — leaving the VPN DNS stuck in every
		// interface after disconnect. We manage DNS exclusively through the
		// scutil DynamicStore hooks below, so the DNS line must not survive.
		if inInterface && strings.HasPrefix(trimmed, "DNS") {
			parts := strings.SplitN(trimmed, "=", 2)
			if len(parts) == 2 {
				dns := strings.TrimSpace(parts[1])
				// Handle comma-separated DNS
				for _, d := range strings.Split(dns, ",") {
					if ip := normalizedDNSIP(d); ip != "" {
						dnsServers = append(dnsServers, ip)
					}
				}
			}
			// Do not carry the DNS line into the emitted config.
			continue
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

				// Register DNS via scutil DynamicStore. SupplementalMatchDomains
				// includes an empty string ("") as a catch-all match — the same
				// trick the official WireGuard.app uses with NEDNSSettings
				// matchDomains:[""]. This routes ALL queries (including bare
				// hostnames like "krl-2") to our DNS, which knows both short
				// internal names and forwards public queries upstream.
				//
				// We do NOT add SearchDomains here: with the bare-name catch-all
				// already routing to our resolver, suffix expansion would only
				// cause spurious NXDOMAIN lookups for non-existent FQDNs.
				domains := `"" ` + strings.Join(searchDomains, " ")
				scutilKey := "State:/Network/Service/cloudnetip-spn/DNS"
				postUpCmd := fmt.Sprintf(
					"printf 'd.init\\nd.add ServerAddresses * %s\\nd.add SupplementalMatchDomains * %s\\nd.add SearchOrder # 1\\nset %s\\nquit\\n' | scutil",
					dnsServers[0], domains, scutilKey,
				)
				preDownCmd := fmt.Sprintf(
					"printf 'remove %s\\nquit\\n' | scutil",
					scutilKey,
				)
				hooks := []string{
					fmt.Sprintf("PostUp = %s", postUpCmd),
					fmt.Sprintf("PreDown = %s", preDownCmd),
				}

				// Insert hooks
				result = append(result[:insertAt], append(hooks, result[insertAt:]...)...)
				break
			}
		}
	}

	return strings.Join(result, "\n")
}
