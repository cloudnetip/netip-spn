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

const privilegedConfigDir = "/var/run/netip-spn"

func privilegedConfigPath() string {
	return filepath.Join(privilegedConfigDir, "wg-netip.conf")
}

func cmdPrivileged(args []string) {
	if os.Geteuid() != 0 {
		fail("_privileged must run as root")
	}
	if len(args) != 2 || (args[0] != "check" && args[0] != "up" && args[0] != "down") {
		fail("usage: _privileged <check|up|down> <source-config>")
	}
	action, source := args[0], filepath.Clean(args[1])
	if !filepath.IsAbs(source) {
		fail("source config must be an absolute path")
	}

	if action == "check" {
		fmt.Println("privileged-helper: ready stats-v1")
		if rx, tx, err := readWireGuardTransferCounters(); err == nil {
			fmt.Printf("wireguard-transfer: %d %d\n", rx, tx)
		}
		return
	}

	if action == "up" {
		if _, err := os.Stat(runtimeName); err == nil {
			fmt.Println("SPN is already up.")
			return
		}
	}
	if action == "down" {
		if _, err := os.Stat(runtimeName); err != nil {
			fmt.Println("SPN is already down.")
			return
		}
	}

	config, err := readAndSanitizePrivilegedConfig(source)
	if err != nil {
		fail("unsafe or invalid config: %v", err)
	}
	if err := os.MkdirAll(privilegedConfigDir, 0o700); err != nil {
		fail("cannot create %s: %v", privilegedConfigDir, err)
	}
	if err := os.Chown(privilegedConfigDir, 0, 0); err != nil {
		fail("cannot secure %s: %v", privilegedConfigDir, err)
	}
	cfg := privilegedConfigPath()
	if err := os.WriteFile(cfg, []byte(config), 0o600); err != nil {
		fail("cannot write privileged config: %v", err)
	}
	if err := os.Chown(cfg, 0, 0); err != nil {
		fail("cannot secure privileged config: %v", err)
	}

	wg, err := findWgQuick()
	if err != nil {
		fail("%v. %s", err, installHint())
	}
	cmd := exec.Command(wg, action, cfg)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fail("%s failed: %v", action, err)
	}
	if action == "down" {
		_ = os.Remove(cfg)
	}
}

func readWireGuardTransferCounters() (uint64, uint64, error) {
	wg, err := findWG()
	if err != nil {
		return 0, 0, err
	}
	interfaceName := tunnelName
	if data, err := os.ReadFile(runtimeName); err == nil {
		if realName := strings.TrimSpace(string(data)); realName != "" {
			interfaceName = realName
		}
	}
	out, err := exec.Command(wg, "show", interfaceName, "dump").Output()
	if err != nil {
		return 0, 0, err
	}
	return parseWireGuardDumpTransfer(string(out))
}

func parseWireGuardDumpTransfer(output string) (uint64, uint64, error) {
	var totalRX, totalTX uint64
	peerCount := 0
	for lineNo, line := range strings.Split(strings.TrimSpace(output), "\n") {
		if lineNo == 0 || strings.TrimSpace(line) == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 8 {
			return 0, 0, fmt.Errorf("unexpected wg dump peer row")
		}
		rx, err := strconv.ParseUint(fields[5], 10, 64)
		if err != nil {
			return 0, 0, fmt.Errorf("invalid wg rx counter: %w", err)
		}
		tx, err := strconv.ParseUint(fields[6], 10, 64)
		if err != nil {
			return 0, 0, fmt.Errorf("invalid wg tx counter: %w", err)
		}
		totalRX += rx
		totalTX += tx
		peerCount++
	}
	if peerCount == 0 {
		return 0, 0, fmt.Errorf("wg dump contains no peers")
	}
	return totalRX, totalTX, nil
}

func findWG() (string, error) {
	if p, err := exec.LookPath("wg"); err == nil {
		return p, nil
	}
	for _, p := range []string{
		"/opt/homebrew/bin/wg",
		"/usr/local/bin/wg",
		"/usr/bin/wg",
		"/usr/sbin/wg",
	} {
		if st, err := os.Stat(p); err == nil && st.Mode().IsRegular() && st.Mode().Perm()&0o111 != 0 {
			return p, nil
		}
	}
	return "", fmt.Errorf("wg not found")
}

func findWgQuick() (string, error) {
	if p, err := exec.LookPath("wg-quick"); err == nil {
		return p, nil
	}
	for _, p := range []string{
		"/opt/homebrew/bin/wg-quick",
		"/usr/local/bin/wg-quick",
		"/usr/bin/wg-quick",
		"/usr/sbin/wg-quick",
	} {
		if st, err := os.Stat(p); err == nil && st.Mode().IsRegular() && st.Mode().Perm()&0o111 != 0 {
			return p, nil
		}
	}
	return "", fmt.Errorf("wg-quick not found")
}

func readAndSanitizePrivilegedConfig(path string) (string, error) {
	st, err := os.Lstat(path)
	if err != nil {
		return "", err
	}
	if st.Mode()&os.ModeSymlink != 0 || !st.Mode().IsRegular() {
		return "", fmt.Errorf("config must be a regular non-symlink file")
	}
	if st.Mode().Perm()&0o022 != 0 {
		return "", fmt.Errorf("config must not be group/world writable")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	if !looksLikeWireGuardConfig(data) {
		return "", fmt.Errorf("missing [Interface] section")
	}

	var safe []string
	for _, line := range strings.Split(string(data), "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") || !strings.Contains(trimmed, "=") {
			safe = append(safe, line)
			continue
		}
		key := strings.ToLower(strings.TrimSpace(strings.SplitN(trimmed, "=", 2)[0]))
		switch key {
		case "preup", "postup", "predown", "postdown", "saveconfig":
			continue
		}
		safe = append(safe, line)
	}

	patched := injectDNSHooks(strings.Join(safe, "\n"))
	return patched, nil
}

func normalizedDNSIP(s string) string {
	ip := net.ParseIP(strings.TrimSpace(s))
	if ip == nil {
		return ""
	}
	return ip.String()
}
