package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestReadAndSanitizePrivilegedConfigStripsUserHooks(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/spn.conf"
	input := `[Interface]
PrivateKey = abc
Address = 10.0.0.2/32
DNS = 10.1.2.3
PostUp = touch /tmp/owned
PreDown = rm -rf /tmp/example
SaveConfig = true

[Peer]
PublicKey = def
AllowedIPs = 0.0.0.0/0
Endpoint = vpn.example:51820
`
	if err := os.WriteFile(path, []byte(input), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := readAndSanitizePrivilegedConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"touch /tmp/owned", "rm -rf", "SaveConfig = true"} {
		if strings.Contains(got, forbidden) {
			t.Fatalf("sanitized config still contains %q:\n%s", forbidden, got)
		}
	}
	if !strings.Contains(got, "ServerAddresses * 10.1.2.3") {
		t.Fatalf("trusted DNS hook not generated:\n%s", got)
	}
}

func TestInjectDNSHooksRejectsShellText(t *testing.T) {
	input := "[Interface]\nPrivateKey = abc\nDNS = 10.1.2.3; touch /tmp/owned\n"
	got := injectDNSHooks(input)
	if strings.Contains(got, "touch /tmp/owned") {
		t.Fatalf("DNS shell text leaked into output:\n%s", got)
	}
	if strings.Contains(got, "PostUp =") {
		t.Fatalf("invalid DNS must not produce a DNS hook:\n%s", got)
	}
}

func TestSudoersRuleTargetsRootOwnedHelper(t *testing.T) {
	rules, err := sudoersRulesFor("alice", "/Users/Alice Example")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(rules, privilegedHelperPath()) {
		t.Fatalf("rule does not target helper: %s", rules)
	}
	if strings.Contains(rules, "wg-quick") {
		t.Fatalf("rule must never grant wg-quick directly: %s", rules)
	}
	if !strings.Contains(rules, "_privileged check") {
		t.Fatalf("rule must allow the side-effect-free helper readiness check: %s", rules)
	}
	if strings.Contains(rules, ".cloudnetip") || strings.Contains(rules, "spn.conf") {
		t.Fatalf("sudoers rule must not trust a user-writable config path: %s", rules)
	}
	for _, action := range []string{"check", "up", "down"} {
		want := privilegedHelperPath() + " _privileged " + action
		if !strings.Contains(rules, want) {
			t.Fatalf("rule does not allow exact %s action: %s", action, rules)
		}
	}
}

func TestSudoersRulePassesVisudoSyntax(t *testing.T) {
	visudo, err := exec.LookPath("visudo")
	if err != nil {
		t.Skip("visudo not installed")
	}
	rules, err := sudoersRulesFor("alice", "/home/alice")
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "sudoers")
	if err := os.WriteFile(path, []byte(rules), 0o440); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command(visudo, "-c", "-f", path).CombinedOutput(); err != nil {
		t.Fatalf("visudo rejected generated rule: %v\n%s\nrule:\n%s", err, out, rules)
	}
}

func TestParseWireGuardDumpTransferSumsPeers(t *testing.T) {
	const dump = `privatekey\tpublickey\t51820\toff
peer1\t(none)\t198.51.100.1:51820\t0.0.0.0/0\t1700000000\t21700000\t5000000\toff
peer2\t(none)\t203.0.113.1:51820\t10.0.0.0/8\t1700000001\t300000\t700000\t25
`
	rx, tx, err := parseWireGuardDumpTransfer(strings.ReplaceAll(dump, `\t`, "\t"))
	if err != nil {
		t.Fatal(err)
	}
	if rx != 22000000 || tx != 5700000 {
		t.Fatalf("got rx=%d tx=%d, want rx=22000000 tx=5700000", rx, tx)
	}
}

func TestParseWireGuardDumpTransferRejectsMalformedPeer(t *testing.T) {
	const dump = "private\tpublic\t51820\toff\npeer-only\n"
	if _, _, err := parseWireGuardDumpTransfer(dump); err == nil {
		t.Fatal("expected malformed peer row to fail")
	}
}

func TestParsePrivilegedRuntimeConfigSeparatesNetworkSettings(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "spn.conf")
	input := `[Interface]
PrivateKey = abc
Address = 10.66.66.2/32, fd00::2/128
DNS = 10.66.66.1
MTU = 1380
Table = auto
PostUp = touch /tmp/owned

[Peer]
PublicKey = def
AllowedIPs = 10.66.66.0/24, fd00::/64
Endpoint = vpn.example:51820
PersistentKeepalive = 25
`
	if err := os.WriteFile(path, []byte(input), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := parsePrivilegedRuntimeConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.MTU != 1380 || cfg.Table != "auto" {
		t.Fatalf("unexpected MTU/Table: %+v", cfg)
	}
	if len(cfg.Addresses) != 2 || len(cfg.DNS) != 1 || len(cfg.AllowedIPs) != 2 {
		t.Fatalf("unexpected parsed config: %+v", cfg)
	}
	for _, forbidden := range []string{"Address =", "DNS =", "MTU =", "Table =", "PostUp ="} {
		if strings.Contains(cfg.WGConfig, forbidden) {
			t.Fatalf("wg setconf payload still contains %q:\n%s", forbidden, cfg.WGConfig)
		}
	}
	for _, required := range []string{"PrivateKey = abc", "AllowedIPs = 10.66.66.0/24", "Endpoint = vpn.example:51820"} {
		if !strings.Contains(cfg.WGConfig, required) {
			t.Fatalf("wg setconf payload lost %q:\n%s", required, cfg.WGConfig)
		}
	}
}

func TestExpectedWireGuardRuntimeVersion(t *testing.T) {
	got := expectedWireGuardRuntimeVersion()
	if got != "wg-1.0.20260223+wireguard-go-0.0.20250522+r1" {
		t.Fatalf("unexpected runtime version %q", got)
	}
}

func TestNormalizePrivilegedAddressAddsHostPrefix(t *testing.T) {
	got4, err := normalizePrivilegedAddress("10.66.66.2")
	if err != nil || got4 != "10.66.66.2/32" {
		t.Fatalf("IPv4 normalization: got %q err=%v", got4, err)
	}
	got6, err := normalizePrivilegedAddress("fd00::2")
	if err != nil || got6 != "fd00::2/128" {
		t.Fatalf("IPv6 normalization: got %q err=%v", got6, err)
	}
}
