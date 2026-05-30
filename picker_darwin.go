//go:build darwin

package main

import (
	"fmt"
	"os/exec"
	"strings"
)

func pickFile() (string, error) {
	script := `POSIX path of (choose file with prompt "Select SPN config" of type {"conf", "txt", "public.text"})`
	out, err := exec.Command("osascript", "-e", script).Output()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			msg := strings.TrimSpace(string(ee.Stderr))
			if strings.Contains(msg, "User canceled") || strings.Contains(msg, "-128") {
				return "", nil
			}
			return "", fmt.Errorf("%s", msg)
		}
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

func installHint() string {
	return "Install with: brew install wireguard-tools"
}
