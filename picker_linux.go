//go:build linux

package main

import (
	"fmt"
	"os/exec"
	"strings"
)

func pickFile() (string, error) {
	if _, err := exec.LookPath("zenity"); err == nil {
		out, err := exec.Command("zenity",
			"--file-selection",
			"--title=Select SPN config",
			"--file-filter=WireGuard config | *.conf *.txt",
			"--file-filter=All files | *",
		).Output()
		if err != nil {
			if ee, ok := err.(*exec.ExitError); ok && ee.ExitCode() == 1 {
				return "", nil // user cancelled
			}
			return "", err
		}
		return strings.TrimSpace(string(out)), nil
	}
	if _, err := exec.LookPath("kdialog"); err == nil {
		out, err := exec.Command("kdialog",
			"--getopenfilename",
			".",
			"*.conf *.txt|WireGuard config",
		).Output()
		if err != nil {
			if ee, ok := err.(*exec.ExitError); ok && ee.ExitCode() == 1 {
				return "", nil
			}
			return "", err
		}
		return strings.TrimSpace(string(out)), nil
	}
	return "", fmt.Errorf("no GUI file picker found — install zenity or kdialog, or pass the path explicitly: netip-spn config <path>")
}

func installHint() string {
	return "Install with your package manager: apt install wireguard-tools | dnf install wireguard-tools | pacman -S wireguard-tools"
}
