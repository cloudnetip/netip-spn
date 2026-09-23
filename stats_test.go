package main

import "testing"

func TestParseIfaceCountersUtunWithoutAddress(t *testing.T) {
	const sample = `Name  Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
utun0 1400  <Link#8>                          4355     0    2689781     5506    10    2466553     0
utun0 1400  192.168.225.1 vpn-192-168-225     4355     -    2689781     5506     -    2466553     -`

	rx, tx := parseIfaceCounters(sample, "utun0")
	if rx != 2689781 || tx != 2466553 {
		t.Fatalf("got rx=%d tx=%d, want rx=2689781 tx=2466553", rx, tx)
	}
}

func TestParseIfaceCountersLinkWithAddress(t *testing.T) {
	const sample = `Name  Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
en0   1500  <Link#4>    d4:9a:20:0d:e6:ec     123     0      45678      90     0      12345     0`

	rx, tx := parseIfaceCounters(sample, "en0")
	if rx != 45678 || tx != 12345 {
		t.Fatalf("got rx=%d tx=%d, want rx=45678 tx=12345", rx, tx)
	}
}

func TestParseWireGuardInterfaceIPs(t *testing.T) {
	const config = `[Interface]
PrivateKey = hidden
Address = 10.44.0.7/32, fd00:44::7/128
DNS = 10.44.0.1

[Peer]
AllowedIPs = 0.0.0.0/0, ::/0
Address = 203.0.113.10/32
`

	ips := parseWireGuardInterfaceIPs(config)
	if len(ips) != 2 {
		t.Fatalf("got %d interface IPs, want 2", len(ips))
	}
	if got := ips[0].String(); got != "10.44.0.7" {
		t.Fatalf("first IP = %q, want 10.44.0.7", got)
	}
	if got := ips[1].String(); got != "fd00:44::7" {
		t.Fatalf("second IP = %q, want fd00:44::7", got)
	}
}

func TestIPFromInterfaceAddr(t *testing.T) {
	for input, want := range map[string]string{
		"10.0.0.5/24": "10.0.0.5",
		"fd00::5/64":  "fd00::5",
		"10.0.0.8":    "10.0.0.8",
	} {
		ip := ipFromInterfaceAddr(input)
		if ip == nil || ip.String() != want {
			t.Fatalf("ipFromInterfaceAddr(%q) = %v, want %s", input, ip, want)
		}
	}
}
