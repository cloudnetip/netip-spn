package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
)

const darwinSystemConfigDir = "/Library/Application Support/Cloudnetip SPN"
const darwinSystemConfigPath = darwinSystemConfigDir + "/spn.conf"

func persistentConfigPath() string {
	if runtime.GOOS == "darwin" {
		return darwinSystemConfigPath
	}
	return userConfigPath()
}

func savePersistentConfig(data []byte) error {
	if !looksLikeWireGuardConfig(data) {
		return fmt.Errorf("file does not look like a WireGuard config (missing [Interface] section)")
	}
	if runtime.GOOS != "darwin" {
		dir := userConfigDir()
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return err
		}
		return os.WriteFile(userConfigPath(), data, 0o600)
	}

	tmp, err := os.CreateTemp("", "netip-spn-config-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}

	exe, err := os.Executable()
	if err != nil {
		return err
	}
	exe, _ = filepath.EvalSymlinks(exe)
	cmd := exec.Command("sudo", exe, "_config-install", tmpName)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return err
	}
	migrateLegacyUserLogForCurrentUser()
	_ = os.RemoveAll(userConfigDir())
	return nil
}

func removePersistentConfig() error {
	if runtime.GOOS != "darwin" {
		if err := os.Remove(userConfigPath()); err != nil && !os.IsNotExist(err) {
			return err
		}
		_ = os.Remove(userWgConfigPath())
		return nil
	}

	exe, err := os.Executable()
	if err != nil {
		return err
	}
	exe, _ = filepath.EvalSymlinks(exe)
	cmd := exec.Command("sudo", exe, "_config-remove")
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func legacyUserConfigExists() bool {
	if runtime.GOOS != "darwin" {
		return false
	}
	_, err := os.Stat(userConfigPath())
	return err == nil
}

func ensurePersistentConfigMigrated() error {
	if runtime.GOOS != "darwin" {
		return nil
	}
	if _, err := os.Stat(darwinSystemConfigPath); err == nil {
		return nil
	}
	if !legacyUserConfigExists() {
		return nil
	}
	data, err := readSafeConfigFile(userConfigPath())
	if err != nil {
		return err
	}
	migrateLegacyUserLogForCurrentUser()
	if err := savePersistentConfig(data); err != nil {
		return err
	}
	return os.RemoveAll(userConfigDir())
}

func migrateLegacyUserLogForCurrentUser() {
	if runtime.GOOS != "darwin" {
		return
	}
	oldPath := filepath.Join(userConfigDir(), "wireguard.log")
	if _, err := os.Stat(oldPath); err != nil {
		return
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return
	}
	newDir := filepath.Join(home, "Library", "Logs", "Cloudnetip SPN")
	newPath := filepath.Join(newDir, "wireguard.log")
	if err := os.MkdirAll(newDir, 0o700); err != nil {
		return
	}
	if _, err := os.Stat(newPath); os.IsNotExist(err) {
		_ = os.Rename(oldPath, newPath)
	}
}

func cmdConfigRootInstall(args []string) {
	if os.Geteuid() != 0 {
		fail("_config-install must run as root")
	}
	if runtime.GOOS != "darwin" || len(args) != 1 {
		fail("usage: _config-install <source-config>")
	}
	if err := installRootConfigFromFile(filepath.Clean(args[0])); err != nil {
		fail("cannot install config: %v", err)
	}
}

func cmdConfigRootRemove() {
	if os.Geteuid() != 0 {
		fail("_config-remove must run as root")
	}
	if runtime.GOOS != "darwin" {
		fail("_config-remove is supported only on macOS")
	}
	if err := os.Remove(darwinSystemConfigPath); err != nil && !os.IsNotExist(err) {
		fail("cannot remove config: %v", err)
	}
}

func installRootConfigFromFile(source string) error {
	data, err := readSafeConfigFile(source)
	if err != nil {
		return err
	}
	return installRootConfigData(data)
}

func installRootConfigData(data []byte) error {
	if !looksLikeWireGuardConfig(data) {
		return fmt.Errorf("missing [Interface] section")
	}
	if err := os.MkdirAll(darwinSystemConfigDir, 0o755); err != nil {
		return err
	}
	if err := os.Chown(darwinSystemConfigDir, 0, 0); err != nil {
		return err
	}
	if err := os.Chmod(darwinSystemConfigDir, 0o755); err != nil {
		return err
	}

	tmp, err := os.CreateTemp(darwinSystemConfigDir, ".spn.conf-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chown(tmpName, 0, 0); err != nil {
		return err
	}
	return os.Rename(tmpName, darwinSystemConfigPath)
}

func migrateLegacyUserConfig(home string) error {
	if runtime.GOOS != "darwin" {
		return nil
	}
	legacyDir := filepath.Join(home, ".cloudnetip")
	legacyConfig := filepath.Join(legacyDir, "spn.conf")

	if _, err := os.Stat(darwinSystemConfigPath); os.IsNotExist(err) {
		if _, legacyErr := os.Stat(legacyConfig); legacyErr == nil {
			if err := installRootConfigFromFile(legacyConfig); err != nil {
				return err
			}
		}
	}
	return os.RemoveAll(legacyDir)
}
