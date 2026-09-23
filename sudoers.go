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

func privilegedHelperPath() string {
	if runtime.GOOS == "darwin" {
		return "/Library/PrivilegedHelperTools/com.cloudnetip.spn.helper"
	}
	return "/usr/local/libexec/netip-spn-helper"
}

func sudoersRulesFor(username, home string) (string, error) {
	if username == "" || strings.ContainsAny(username, " \t\r\n:#\\") {
		return "", fmt.Errorf("unsafe username %q", username)
	}
	source := filepath.Join(home, ".cloudnetip", "spn.conf")
	for _, p := range []string{source, privilegedHelperPath()} {
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
	helper, src := escape(privilegedHelperPath()), escape(source)
	return fmt.Sprintf(
		"# Installed by netip-spn. Remove with: netip-spn sudoers remove\n"+
			"# Passwordless access is limited to the root-owned helper and this user's SPN config.\n"+
			"%s ALL=(root) NOPASSWD: %s _privileged check %s, %s _privileged up %s, %s _privileged down %s\n",
		username, helper, src, helper, src, helper, src,
	), nil
}

func activeNow() bool {
	u, err := user.Current()
	if err != nil || u.Username == "" || u.HomeDir == "" {
		return false
	}
	source := filepath.Join(u.HomeDir, ".cloudnetip", "spn.conf")

	cmd := exec.Command("sudo", "-n", privilegedHelperPath(), "_privileged", "check", source)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return false
	}
	return strings.Contains(string(out), "privileged-helper: ready stats-v1")
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
		fmt.Println("Already enabled — passwordless connect/disconnect is active.")
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

	fmt.Println("Installing the root-owned helper and sudoers rule (one-time password prompt)…")
	cmd := exec.Command("sudo", exe, "_sudoers-install", u.Username, u.HomeDir)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fail("install failed: %v", err)
	}
	if !activeNow() {
		fail("installed, but could not verify passwordless access")
	}
	fmt.Println("✓ Passwordless connect/disconnect enabled")
	fmt.Println("  Helper: " + privilegedHelperPath())
	fmt.Println("  Rule:   " + sudoersFile)
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
	fmt.Println("✓ Passwordless mode disabled")
}

func cmdSudoersRootInstall(args []string) {
	if os.Geteuid() != 0 {
		fail("_sudoers-install must run as root")
	}
	if len(args) != 2 {
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
	helper := privilegedHelperPath()
	if err := os.MkdirAll(filepath.Dir(helper), 0o755); err != nil {
		fail("cannot create helper directory: %v", err)
	}
	if err := copyRootExecutable(exe, helper); err != nil {
		fail("cannot install helper: %v", err)
	}

	if err := installSudoersRules(rules); err != nil {
		_ = os.Remove(helper)
		fail("cannot install sudoers rule: %v", err)
	}
}

func cmdSudoersRootRemove() {
	if os.Geteuid() != 0 {
		fail("_sudoers-remove must run as root")
	}
	if err := os.Remove(sudoersFile); err != nil && !os.IsNotExist(err) {
		fail("cannot remove %s: %v", sudoersFile, err)
	}
	if err := os.Remove(privilegedHelperPath()); err != nil && !os.IsNotExist(err) {
		fail("cannot remove helper: %v", err)
	}
}

func copyRootExecutable(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	tmp, err := os.CreateTemp(filepath.Dir(dst), ".netip-spn-helper-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.ReadFrom(in); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o755); err != nil {
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
