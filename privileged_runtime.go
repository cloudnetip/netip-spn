package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const privilegedDNSKey = "State:/Network/Service/cloudnetip-spn/DNS"

type privilegedRuntimeConfig struct {
	WGConfig   string
	Addresses  []string
	DNS        []string
	MTU        int
	Table      string
	AllowedIPs []string
}

type privilegedRoute struct {
	Family      string `json:"family"`
	Destination string `json:"destination"`
	Gateway     string `json:"gateway,omitempty"`
	Interface   string `json:"interface,omitempty"`
}

type privilegedTunnelState struct {
	Interface string            `json:"interface"`
	Routes    []privilegedRoute `json:"routes"`
	DNS       bool              `json:"dns"`
}

func privilegedRuntimeRoot() string {
	return filepath.Dir(privilegedHelperPath())
}

func privilegedWGPath() string {
	return filepath.Join(privilegedRuntimeRoot(), "wg")
}

func privilegedWireGuardGoPath() string {
	return filepath.Join(privilegedRuntimeRoot(), "wireguard-go")
}

func privilegedRuntimeVersionPath() string {
	return filepath.Join(privilegedRuntimeRoot(), "runtime.version")
}

func privilegedStatePath() string {
	return filepath.Join(privilegedConfigDir, "state.json")
}

func installedWireGuardRuntimeVersion() string {
	data, err := os.ReadFile(privilegedRuntimeVersionPath())
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

func privilegedRuntimeReady() bool {
	if installedWireGuardRuntimeVersion() != expectedWireGuardRuntimeVersion() {
		return false
	}
	root, err := os.Lstat(privilegedRuntimeRoot())
	if err != nil || !root.IsDir() || root.Mode().Perm()&0o022 != 0 || fileOwnerUID(root) != 0 {
		return false
	}
	for _, p := range []string{privilegedWGPath(), privilegedWireGuardGoPath(), privilegedRuntimeVersionPath()} {
		st, err := os.Lstat(p)
		if err != nil || !st.Mode().IsRegular() || st.Mode().Perm()&0o022 != 0 || fileOwnerUID(st) != 0 {
			return false
		}
		if p != privilegedRuntimeVersionPath() && st.Mode().Perm()&0o111 == 0 {
			return false
		}
	}
	return true
}

func fileOwnerUID(info os.FileInfo) uint32 {
	if stat, ok := info.Sys().(*syscall.Stat_t); ok {
		return stat.Uid
	}
	return ^uint32(0)
}

func parsePrivilegedRuntimeConfig(path string) (privilegedRuntimeConfig, error) {
	data, err := readSafeConfigFile(path)
	if err != nil {
		return privilegedRuntimeConfig{}, err
	}

	cfg := privilegedRuntimeConfig{Table: "auto"}
	var wgLines []string
	section := ""
	for _, raw := range strings.Split(string(data), "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			wgLines = append(wgLines, raw)
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.ToLower(strings.TrimSpace(line[1 : len(line)-1]))
			wgLines = append(wgLines, raw)
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			wgLines = append(wgLines, raw)
			continue
		}
		key := strings.ToLower(strings.TrimSpace(parts[0]))
		value := strings.TrimSpace(strings.SplitN(parts[1], "#", 2)[0])

		if section == "interface" {
			switch key {
			case "address":
				for _, item := range splitCommaSpace(value) {
					normalized, err := normalizePrivilegedAddress(item)
					if err != nil {
						return cfg, err
					}
					cfg.Addresses = append(cfg.Addresses, normalized)
				}
				continue
			case "dns":
				for _, item := range splitCommaSpace(value) {
					if ip := net.ParseIP(item); ip != nil {
						cfg.DNS = append(cfg.DNS, ip.String())
					}
				}
				continue
			case "mtu":
				mtu, err := strconv.Atoi(value)
				if err != nil || mtu < 576 || mtu > 65535 {
					return cfg, fmt.Errorf("invalid MTU %q", value)
				}
				cfg.MTU = mtu
				continue
			case "table":
				v := strings.ToLower(value)
				if v != "auto" && v != "main" && v != "off" {
					return cfg, fmt.Errorf("Darwin supports Table=auto|main|off, got %q", value)
				}
				cfg.Table = v
				continue
			case "preup", "postup", "predown", "postdown", "saveconfig":
				continue
			}
		}

		if section == "peer" && key == "allowedips" {
			for _, item := range splitCommaSpace(value) {
				if _, network, err := net.ParseCIDR(item); err == nil {
					cfg.AllowedIPs = append(cfg.AllowedIPs, network.String())
				} else {
					return cfg, fmt.Errorf("invalid AllowedIPs entry %q", item)
				}
			}
		}
		wgLines = append(wgLines, raw)
	}
	if len(cfg.Addresses) == 0 {
		return cfg, errors.New("missing Interface Address")
	}
	cfg.WGConfig = strings.TrimSpace(strings.Join(wgLines, "\n")) + "\n"
	return cfg, nil
}

func readSafeConfigFile(path string) ([]byte, error) {
	st, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if st.Mode()&os.ModeSymlink != 0 || !st.Mode().IsRegular() {
		return nil, errors.New("config must be a regular non-symlink file")
	}
	if st.Mode().Perm()&0o022 != 0 {
		return nil, errors.New("config must not be group/world writable")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if !looksLikeWireGuardConfig(data) {
		return nil, errors.New("missing [Interface] section")
	}
	return data, nil
}

func splitCommaSpace(value string) []string {
	return strings.FieldsFunc(value, func(r rune) bool { return r == ',' || r == ' ' || r == '\t' })
}

func normalizePrivilegedAddress(value string) (string, error) {
	if _, network, err := net.ParseCIDR(value); err == nil {
		ip := net.ParseIP(strings.SplitN(value, "/", 2)[0])
		if ip == nil {
			return "", fmt.Errorf("invalid Address %q", value)
		}
		ones, _ := network.Mask.Size()
		return fmt.Sprintf("%s/%d", ip.String(), ones), nil
	}
	ip := net.ParseIP(value)
	if ip == nil {
		return "", fmt.Errorf("invalid Address %q", value)
	}
	if ip.To4() != nil {
		return ip.String() + "/32", nil
	}
	return ip.String() + "/128", nil
}

func privilegedRuntimeUp(source string) error {
	if !privilegedRuntimeReady() {
		return fmt.Errorf("bundled WireGuard runtime is missing or outdated")
	}
	if data, err := os.ReadFile(runtimeName); err == nil {
		if _, stateErr := os.Stat(privilegedStatePath()); stateErr == nil {
			return nil
		}
		iface := strings.TrimSpace(string(data))
		if iface != "" {
			if _, socketErr := os.Stat(filepath.Join(filepath.Dir(runtimeName), iface+".sock")); socketErr == nil {
				return errors.New("a WireGuard tunnel is already active outside the GUI runtime; disconnect it first")
			}
		}
		_ = os.Remove(runtimeName)
	}
	cfg, err := parsePrivilegedRuntimeConfig(source)
	if err != nil {
		return fmt.Errorf("unsafe or invalid config: %w", err)
	}
	if err := os.MkdirAll(privilegedConfigDir, 0o700); err != nil {
		return err
	}
	if err := os.Chown(privilegedConfigDir, 0, 0); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(runtimeName), 0o755); err != nil {
		return err
	}

	cfgPath := privilegedConfigPath()
	if err := os.WriteFile(cfgPath, []byte(cfg.WGConfig), 0o600); err != nil {
		return err
	}
	if err := os.Chown(cfgPath, 0, 0); err != nil {
		return err
	}

	state := privilegedTunnelState{}
	cleanup := func() {
		_ = removePrivilegedDNS()
		removePrivilegedRoutes(state.Routes)
		if state.Interface != "" {
			_ = os.Remove(filepath.Join(filepath.Dir(runtimeName), state.Interface+".sock"))
		}
		_ = os.Remove(runtimeName)
		_ = os.Remove(privilegedStatePath())
		_ = os.Remove(privilegedConfigPath())
	}

	if err := startPrivilegedWireGuardGo(); err != nil {
		cleanup()
		return err
	}
	iface, err := waitForPrivilegedInterface(4 * time.Second)
	if err != nil {
		cleanup()
		return err
	}
	state.Interface = iface

	if err := runRootCommand(privilegedWGPath(), "setconf", iface, cfgPath); err != nil {
		cleanup()
		return err
	}
	for _, address := range cfg.Addresses {
		if err := addPrivilegedAddress(iface, address); err != nil {
			cleanup()
			return err
		}
	}
	mtu := cfg.MTU
	if mtu == 0 {
		mtu = autoPrivilegedMTU()
	}
	if err := runRootCommand("/sbin/ifconfig", iface, "mtu", strconv.Itoa(mtu)); err != nil {
		cleanup()
		return err
	}
	if err := runRootCommand("/sbin/ifconfig", iface, "up"); err != nil {
		cleanup()
		return err
	}

	if cfg.Table != "off" {
		routes, err := addPrivilegedRoutes(iface, cfg.AllowedIPs, cfg.Table)
		if err != nil {
			state.Routes = routes
			cleanup()
			return err
		}
		state.Routes = routes
	}
	if len(cfg.DNS) > 0 {
		if err := setPrivilegedDNS(cfg.DNS); err != nil {
			cleanup()
			return err
		}
		state.DNS = true
	}
	if err := writePrivilegedState(state); err != nil {
		cleanup()
		return err
	}
	return nil
}

func privilegedRuntimeDown() error {
	state, err := readPrivilegedState()
	if err != nil {
		if !os.IsNotExist(err) {
			return err
		}
		if data, nameErr := os.ReadFile(runtimeName); nameErr == nil {
			iface := strings.TrimSpace(string(data))
			if iface != "" {
				if _, socketErr := os.Stat(filepath.Join(filepath.Dir(runtimeName), iface+".sock")); socketErr == nil {
					return errors.New("the active WireGuard tunnel was not started by the GUI runtime; disconnect it with the CLI")
				}
			}
			_ = os.Remove(runtimeName)
		}
		_ = removePrivilegedDNS()
		_ = os.Remove(privilegedConfigPath())
		return nil
	}

	_ = removePrivilegedDNS()
	removePrivilegedRoutes(state.Routes)
	if state.Interface != "" {
		_ = os.Remove(filepath.Join(filepath.Dir(runtimeName), state.Interface+".sock"))
	}
	_ = os.Remove(runtimeName)
	_ = os.Remove(privilegedStatePath())
	_ = os.Remove(privilegedConfigPath())
	return nil
}

func startPrivilegedWireGuardGo() error {
	cmd := exec.Command(privilegedWireGuardGoPath(), "utun")
	cmd.Env = []string{"WG_TUN_NAME_FILE=" + runtimeName, "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C"}
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("wireguard-go failed: %w", err)
	}
	return nil
}

func waitForPrivilegedInterface(timeout time.Duration) (string, error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		data, err := os.ReadFile(runtimeName)
		if err == nil {
			iface := strings.TrimSpace(string(data))
			if strings.HasPrefix(iface, "utun") {
				if _, err := os.Stat(filepath.Join(filepath.Dir(runtimeName), iface+".sock")); err == nil {
					return iface, nil
				}
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	return "", errors.New("wireguard-go did not create a utun interface")
}

func addPrivilegedAddress(iface, address string) error {
	ip, _, err := net.ParseCIDR(address)
	if err != nil {
		return err
	}
	if ip.To4() != nil {
		return runRootCommand("/sbin/ifconfig", iface, "inet", address, ip.String(), "alias")
	}
	return runRootCommand("/sbin/ifconfig", iface, "inet6", address, "alias")
}

func autoPrivilegedMTU() int {
	iface := routeField("inet", "default", "interface")
	if iface == "" {
		return 1420
	}
	out, err := exec.Command("/sbin/ifconfig", iface).Output()
	if err != nil {
		return 1420
	}
	fields := strings.Fields(string(out))
	for i := 0; i+1 < len(fields); i++ {
		if fields[i] == "mtu" {
			if n, err := strconv.Atoi(fields[i+1]); err == nil && n > 80 {
				return n - 80
			}
		}
	}
	return 1420
}

func addPrivilegedRoutes(iface string, allowed []string, table string) ([]privilegedRoute, error) {
	gateway4 := routeField("inet", "default", "gateway")
	gateway6 := routeField("inet6", "default", "gateway")
	allowed = append([]string(nil), allowed...)
	sort.SliceStable(allowed, func(i, j int) bool {
		_, ni, _ := net.ParseCIDR(allowed[i])
		_, nj, _ := net.ParseCIDR(allowed[j])
		bi, _ := ni.Mask.Size()
		bj, _ := nj.Mask.Size()
		return bi > bj
	})

	var routes []privilegedRoute
	full4, full6 := false, false
	for _, destination := range allowed {
		ip, network, err := net.ParseCIDR(destination)
		if err != nil {
			return routes, err
		}
		ones, _ := network.Mask.Size()
		family := "inet"
		if ip.To4() == nil {
			family = "inet6"
		}
		if ones == 0 && table == "auto" {
			if family == "inet" {
				full4 = true
				for _, half := range []string{"0.0.0.0/1", "128.0.0.0/1"} {
					r := privilegedRoute{Family: family, Destination: half, Interface: iface}
					if err := addPrivilegedRoute(r); err != nil {
						return routes, err
					}
					routes = append(routes, r)
				}
			} else {
				full6 = true
				for _, half := range []string{"::/1", "8000::/1"} {
					r := privilegedRoute{Family: family, Destination: half, Interface: iface}
					if err := addPrivilegedRoute(r); err != nil {
						return routes, err
					}
					routes = append(routes, r)
				}
			}
			continue
		}
		r := privilegedRoute{Family: family, Destination: network.String(), Interface: iface}
		if err := addPrivilegedRoute(r); err != nil {
			if !strings.Contains(err.Error(), "File exists") {
				return routes, err
			}
			continue
		}
		routes = append(routes, r)
	}

	if full4 || full6 {
		endpoints := privilegedEndpoints(iface)
		for _, endpoint := range endpoints {
			ip := net.ParseIP(endpoint)
			if ip == nil {
				continue
			}
			family := "inet"
			if ip.To4() == nil {
				family = "inet6"
				if !full6 {
					continue
				}
			} else if !full4 {
				continue
			}
			gateway := gateway4
			if family == "inet6" {
				gateway = gateway6
			}
			if gateway == "" {
				continue
			}
			r := privilegedRoute{Family: family, Destination: endpoint, Gateway: gateway}
			if err := addPrivilegedRoute(r); err == nil {
				routes = append(routes, r)
			}
		}
	}
	return routes, nil
}

func addPrivilegedRoute(r privilegedRoute) error {
	args := []string{"-q", "-n", "add", "-" + r.Family, r.Destination}
	if r.Gateway != "" {
		args = append(args, "-gateway", r.Gateway)
	} else {
		args = append(args, "-interface", r.Interface)
	}
	return runRootCommand("/sbin/route", args...)
}

func removePrivilegedRoutes(routes []privilegedRoute) {
	for i := len(routes) - 1; i >= 0; i-- {
		r := routes[i]
		_ = runRootCommand("/sbin/route", "-q", "-n", "delete", "-"+r.Family, r.Destination)
	}
}

func routeField(family, destination, field string) string {
	out, err := exec.Command("/sbin/route", "-n", "get", "-"+family, destination).CombinedOutput()
	if err != nil {
		return ""
	}
	prefix := field + ":"
	scanner := bufio.NewScanner(strings.NewReader(string(out)))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(line, prefix) {
			return strings.TrimSpace(strings.TrimPrefix(line, prefix))
		}
	}
	return ""
}

func privilegedEndpoints(iface string) []string {
	out, err := exec.Command(privilegedWGPath(), "show", iface, "endpoints").Output()
	if err != nil {
		return nil
	}
	var endpoints []string
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 || fields[1] == "(none)" {
			continue
		}
		host := fields[1]
		if strings.HasPrefix(host, "[") {
			if end := strings.LastIndex(host, "]:"); end > 0 {
				host = host[1:end]
			}
		} else if idx := strings.LastIndex(host, ":"); idx > 0 {
			host = host[:idx]
		}
		if ip := net.ParseIP(host); ip != nil {
			endpoints = append(endpoints, ip.String())
		}
	}
	return endpoints
}

func setPrivilegedDNS(servers []string) error {
	if len(servers) == 0 {
		return nil
	}
	var script strings.Builder
	script.WriteString("d.init\n")
	script.WriteString("d.add ServerAddresses *")
	for _, server := range servers {
		script.WriteString(" ")
		script.WriteString(server)
	}
	script.WriteString("\n")
	script.WriteString("d.add SupplementalMatchDomains * \"\" netip internal local\n")
	script.WriteString("d.add SearchOrder # 1\n")
	script.WriteString("set " + privilegedDNSKey + "\nquit\n")
	cmd := exec.Command("/usr/sbin/scutil")
	cmd.Stdin = strings.NewReader(script.String())
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("scutil DNS setup failed: %w", err)
	}
	return nil
}

func removePrivilegedDNS() error {
	cmd := exec.Command("/usr/sbin/scutil")
	cmd.Stdin = strings.NewReader("remove " + privilegedDNSKey + "\nquit\n")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func writePrivilegedState(state privilegedTunnelState) error {
	data, err := json.Marshal(state)
	if err != nil {
		return err
	}
	if err := os.WriteFile(privilegedStatePath(), data, 0o600); err != nil {
		return err
	}
	return os.Chown(privilegedStatePath(), 0, 0)
}

func readPrivilegedState() (privilegedTunnelState, error) {
	var state privilegedTunnelState
	data, err := os.ReadFile(privilegedStatePath())
	if err != nil {
		return state, err
	}
	err = json.Unmarshal(data, &state)
	return state, err
}

func runRootCommand(path string, args ...string) error {
	cmd := exec.Command(path, args...)
	cmd.Env = []string{"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C"}
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s %s: %w", path, strings.Join(args, " "), err)
	}
	return nil
}
