package main

import (
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"strings"
)

const sudoersFile = "/etc/sudoers.d/netip-spn"
const legacyPrivilegedHelper = "/Library/PrivilegedHelperTools/com.cloudnetip.spn.helper"

func privilegedHelperPath() string {
	if runtime.GOOS == "darwin" {
		return "/Library/PrivilegedHelperTools/cloudnetip-spn/helper"
	}
	return "/usr/local/libexec/netip-spn-helper"
}

func sudoersRulesFor(username, home string) (string, error) {
	if username == "" || strings.ContainsAny(username, " \t\r\n:#\\") {
		return "", fmt.Errorf("unsafe username %q", username)
	}
	for _, p := range []string{home, privilegedHelperPath()} {
		if strings.ContainsAny(p, "\n\r") {
			return "", fmt.Errorf("unsafe path %q", p)
		}
	}
	escape := func(s string) string {
		r := strings.NewReplacer(
			"\\", "\\\\", " ", "\\ ", "\t", "\\\t",
			",", "\\,", ":", "\\:", "#", "\\#",
		)
		return r.Replace(s)
	}
	helper := escape(privilegedHelperPath())
	return fmt.Sprintf(
		"# Installed by netip-spn. Remove with: netip-spn sudoers remove\n"+
			"%s ALL=(root) NOPASSWD: %s _privileged check, %s _privileged up, %s _privileged down\n",
		username, helper, helper, helper,
	), nil
}

func activeNow() bool {
	u, err := user.Current()
	if err != nil || u.Username == "" || u.HomeDir == "" {
		return false
	}
	cmd := exec.Command("sudo", "-n", privilegedHelperPath(), "_privileged", "check")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return false
	}
	text := string(out)
	return strings.Contains(text, "privileged-helper: ready stats-v3") &&
		strings.Contains(text, "runtime="+expectedWireGuardRuntimeVersion())
}

func cmdSudoers(args []string) {
	if len(args) > 1 {
		fail("usage: netip-spn sudoers [check|remove]")
	}
	action := "install"
	if len(args) == 1 {
		action = args[0]
	}
	switch action {
	case "install":
		cmdSudoersInstall()
	case "check":
		cmdSudoersCheck()
	case "remove":
		cmdSudoersRemove()
	default:
		fail("usage: netip-spn sudoers [check|remove]")
	}
}

func cmdSudoersCheck() {
	if activeNow() {
		fmt.Println("sudoers: enabled")
		return
	}
	fmt.Println("sudoers: disabled")
}

func cmdSudoersInstall() {
	if activeNow() {
		fmt.Println("Already enabled — GUI WireGuard helper is ready.")
		return
	}
	u, err := user.Current()
	if err != nil {
		fail("cannot resolve current user: %v", err)
	}
	exe, err := os.Executable()
	if err != nil {
		fail("cannot resolve executable path: %v", err)
	}
	exe, _ = filepath.EvalSymlinks(exe)

	args := []string{"_sudoers-install", u.Username, u.HomeDir}
	if runtime.GOOS == "darwin" {
		runtimeSource := findBundledRuntimeSource()
		if runtimeSource == "" {
			fail("Cloudnetip SPN.app bundled WireGuard runtime not found")
		}
		args = append(args, runtimeSource)
	}

	fmt.Println("Installing the root-owned helper and bundled WireGuard runtime (one-time password prompt)…")
	cmd := exec.Command("sudo", append([]string{exe}, args...)...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fail("install failed: %v", err)
	}
	if !activeNow() {
		fail("installed, but could not verify passwordless GUI access")
	}
	fmt.Println("✓ Passwordless GUI connect/disconnect enabled")
	fmt.Println("  Helper:  " + privilegedHelperPath())
	fmt.Println("  Runtime: " + expectedWireGuardRuntimeVersion())
	fmt.Println("  Rule:    " + sudoersFile)
}

func findBundledRuntimeSource() string {
	if p := strings.TrimSpace(os.Getenv("NETIP_SPN_RUNTIME_DIR")); p != "" {
		if runtimeSourceMatches(p) {
			return p
		}
	}
	for _, p := range []string{
		"/Applications/Cloudnetip SPN.app/Contents/Resources/WireGuard",
		filepath.Join(os.Getenv("HOME"), "Applications/Cloudnetip SPN.app/Contents/Resources/WireGuard"),
	} {
		if runtimeSourceMatches(p) {
			return p
		}
	}
	return ""
}

func runtimeSourceMatches(dir string) bool {
	data, err := os.ReadFile(filepath.Join(dir, "runtime.version"))
	return err == nil && strings.TrimSpace(string(data)) == expectedWireGuardRuntimeVersion()
}

func cmdSudoersRemove() {
	exe, err := os.Executable()
	if err != nil {
		fail("cannot resolve executable path: %v", err)
	}
	exe, _ = filepath.EvalSymlinks(exe)
	cmd := exec.Command("sudo", exe, "_sudoers-remove")
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fail("remove failed: %v", err)
	}
	fmt.Println("✓ Passwordless GUI mode disabled")
}

func cmdSudoersRootInstall(args []string) {
	if os.Geteuid() != 0 {
		fail("_sudoers-install must run as root")
	}
	wantArgs := 2
	if runtime.GOOS == "darwin" {
		wantArgs = 3
	}
	if len(args) != wantArgs {
		if runtime.GOOS == "darwin" {
			fail("usage: _sudoers-install <username> <home> <bundled-runtime-dir>")
		}
		fail("usage: _sudoers-install <username> <home>")
	}
	username, home := args[0], filepath.Clean(args[1])
	u, err := user.Lookup(username)
	if err != nil {
		fail("unknown user %q: %v", username, err)
	}
	if filepath.Clean(u.HomeDir) != home {
		fail("home mismatch for %s", username)
	}
	rules, err := sudoersRulesFor(username, home)
	if err != nil {
		fail("cannot build sudoers rule: %v", err)
	}

	exe, err := os.Executable()
	if err != nil {
		fail("cannot resolve executable: %v", err)
	}
	exe, _ = filepath.EvalSymlinks(exe)

	if runtime.GOOS == "darwin" {
		if err := installPrivilegedRuntime(filepath.Clean(args[2])); err != nil {
			fail("cannot install bundled WireGuard runtime: %v", err)
		}
	}

	helper := privilegedHelperPath()
	if err := os.MkdirAll(filepath.Dir(helper), 0o755); err != nil {
		fail("cannot create helper directory: %v", err)
	}
	if err := os.Chown(filepath.Dir(helper), 0, 0); err != nil {
		fail("cannot secure helper directory: %v", err)
	}
	if err := copyRootExecutable(exe, helper); err != nil {
		fail("cannot install helper: %v", err)
	}
	if runtime.GOOS == "darwin" {
		if err := migrateLegacyUserConfig(home); err != nil {
			fail("cannot migrate legacy config: %v", err)
		}
	}

	if err := installSudoersRules(rules); err != nil {
		fail("cannot install sudoers rule: %v", err)
	}
	if runtime.GOOS == "darwin" {
		_ = os.Remove(legacyPrivilegedHelper)
	}
}

func installPrivilegedRuntime(sourceDir string) error {
	if runtime.GOOS != "darwin" {
		return nil
	}
	if !runtimeSourceMatches(sourceDir) {
		return fmt.Errorf("runtime.version does not match %s", expectedWireGuardRuntimeVersion())
	}
	root := privilegedRuntimeRoot()
	if err := os.MkdirAll(root, 0o755); err != nil {
		return err
	}
	if err := os.Chown(root, 0, 0); err != nil {
		return err
	}
	if err := os.Chmod(root, 0o755); err != nil {
		return err
	}
	for _, name := range []string{"wg", "wireguard-go"} {
		src := filepath.Join(sourceDir, name)
		st, err := os.Lstat(src)
		if err != nil {
			return err
		}
		if st.Mode()&os.ModeSymlink != 0 || !st.Mode().IsRegular() {
			return fmt.Errorf("%s must be a regular non-symlink file", src)
		}
		if err := copyRootExecutable(src, filepath.Join(root, name)); err != nil {
			return err
		}
	}
	return copyRootFile(
		filepath.Join(sourceDir, "runtime.version"),
		privilegedRuntimeVersionPath(),
		0o644,
	)
}

func cmdSudoersRootRemove() {
	if os.Geteuid() != 0 {
		fail("_sudoers-remove must run as root")
	}
	if err := os.Remove(sudoersFile); err != nil && !os.IsNotExist(err) {
		fail("cannot remove %s: %v", sudoersFile, err)
	}
	if runtime.GOOS == "darwin" {
		_ = privilegedRuntimeDown()
		if err := os.RemoveAll(privilegedRuntimeRoot()); err != nil {
			fail("cannot remove helper runtime: %v", err)
		}
		_ = os.Remove(legacyPrivilegedHelper)
	} else if err := os.Remove(privilegedHelperPath()); err != nil && !os.IsNotExist(err) {
		fail("cannot remove helper: %v", err)
	}
}

func copyRootExecutable(src, dst string) error {
	return copyRootFile(src, dst, 0o755)
}

func copyRootFile(src, dst string, mode os.FileMode) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(dst), ".netip-spn-install-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.ReadFrom(in); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chown(tmpName, 0, 0); err != nil {
		return err
	}
	return os.Rename(tmpName, dst)
}

func installSudoersRules(rules string) error {
	dir := filepath.Dir(sudoersFile)
	tmp, err := os.CreateTemp(dir, ".netip-spn-sudoers-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if _, err := tmp.WriteString(rules); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o440); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chown(name, 0, 0); err != nil {
		return err
	}
	if out, err := exec.Command("visudo", "-c", "-f", name).CombinedOutput(); err != nil {
		return fmt.Errorf("visudo rejected rule: %s", strings.TrimSpace(string(out)))
	}
	return os.Rename(name, sudoersFile)
}
