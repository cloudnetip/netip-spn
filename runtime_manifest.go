package main

import (
	_ "embed"
	"fmt"
	"strings"
)

//go:embed wireguard-runtime.conf
var wireGuardRuntimeManifest string

type wireGuardRuntimeInfo struct {
	ToolsVersion string
	ToolsSHA256  string
	GoVersion    string
	GoSHA256     string
	Revision     string
}

func bundledWireGuardRuntimeInfo() (wireGuardRuntimeInfo, error) {
	values := make(map[string]string)
	for _, raw := range strings.Split(wireGuardRuntimeManifest, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 || strings.TrimSpace(parts[0]) == "" || strings.TrimSpace(parts[1]) == "" {
			return wireGuardRuntimeInfo{}, fmt.Errorf("invalid wireguard-runtime.conf line %q", raw)
		}
		values[strings.TrimSpace(parts[0])] = strings.TrimSpace(parts[1])
	}
	info := wireGuardRuntimeInfo{
		ToolsVersion: values["WIREGUARD_TOOLS_VERSION"],
		ToolsSHA256:  values["WIREGUARD_TOOLS_SHA256"],
		GoVersion:    values["WIREGUARD_GO_VERSION"],
		GoSHA256:     values["WIREGUARD_GO_SHA256"],
		Revision:     values["RUNTIME_REVISION"],
	}
	if info.ToolsVersion == "" || info.GoVersion == "" || info.Revision == "" {
		return wireGuardRuntimeInfo{}, fmt.Errorf("wireguard runtime manifest is incomplete")
	}
	return info, nil
}

func expectedWireGuardRuntimeVersion() string {
	info, err := bundledWireGuardRuntimeInfo()
	if err != nil {
		return "invalid"
	}
	return fmt.Sprintf("wg-%s+wireguard-go-%s+r%s", info.ToolsVersion, info.GoVersion, info.Revision)
}
