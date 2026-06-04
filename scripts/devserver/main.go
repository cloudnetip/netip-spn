// Stub auth/config server for local development of `netip-spn auth login`.
//
// Flow (Spotify-style loopback redirect, no persistent token):
//
//	GET  /app/shared/authorize - HTML page: select SPN, optional OTP
//	POST /api/spn/authorize - validates selection, 302s to redirect_uri
//	                          with one-time code + state
//	POST /api/spn/clients/config/claim - code + code_verifier → wg-quick config
//	                                     (PKCE; single-use; no Bearer ever issued)
//
// The client keeps spn.conf only — that file is itself the credential
// (PrivateKey + Endpoint), so no separate token is needed.
//
// Run:  go run ./scripts/devserver
// Use:  NETIP_API_URL=http://localhost:8080 ./netip-spn auth login
package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

const (
	addr      = ":8080"
	claimTTL  = 5 * time.Minute
	otpDevVal = "123456" // hard-coded OTP for the "dev" mock SPN
)

type spnEntry struct {
	ID          string
	Name        string
	RequiresOTP bool
	Conf        string
}

var spns = []spnEntry{
	{ID: "prod", Name: "Production SPN", Conf: confProd},
	{ID: "staging", Name: "Staging SPN", Conf: confStaging},
	{ID: "dev", Name: "Dev SPN (OTP required, try " + otpDevVal + ")", RequiresOTP: true, Conf: confDev},
}

type pendingClaim struct {
	Conf          string
	RedirectURI   string
	CodeChallenge string
	ExpiresAt     time.Time
}

var (
	mu     sync.Mutex
	claims = map[string]*pendingClaim{}
)

func main() {
	http.HandleFunc("GET /app/shared/authorize", handleAuthorize)
	http.HandleFunc("POST /api/spn/authorize", handleAuthorize)
	http.HandleFunc("/api/spn/clients/config/claim", handleClaim)

	log.Printf("netip-spn devserver listening on %s", addr)
	log.Printf("set NETIP_API_URL=http://localhost%s on the CLI", addr)
	log.Fatal(http.ListenAndServe(addr, nil))
}

// handleAuthorize serves the selection page on GET and processes the choice
// on POST. POST validates required params, optional OTP, mints a one-time
// code, then 302s to the loopback redirect_uri.
func handleAuthorize(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	if r.Method == http.MethodPost {
		// Form POST carries the original auth params as hidden inputs.
		if err := r.ParseForm(); err != nil {
			http.Error(w, "invalid form", http.StatusBadRequest)
			return
		}
		q = r.PostForm
	}
	redirectURI := q.Get("redirect_uri")
	state := q.Get("state")
	challenge := q.Get("code_challenge")
	method := q.Get("code_challenge_method")
	respType := q.Get("response_type")

	if respType != "code" || redirectURI == "" || state == "" || challenge == "" || method != "S256" {
		http.Error(w, "invalid_request", http.StatusBadRequest)
		return
	}
	if !isLoopbackRedirect(redirectURI) {
		http.Error(w, "redirect_uri must be loopback", http.StatusBadRequest)
		return
	}

	if r.Method == http.MethodPost {
		spnID := q.Get("spn_id")
		otp := q.Get("otp")
		spn := findSPN(spnID)
		if spn == nil {
			renderSelect(w, q, "Choose a network.")
			return
		}
		if spn.RequiresOTP && otp != otpDevVal {
			renderSelect(w, q, "Bad OTP. Try "+otpDevVal+".")
			return
		}

		code := randomHex(20)
		mu.Lock()
		claims[code] = &pendingClaim{
			Conf:          spn.Conf,
			RedirectURI:   redirectURI,
			CodeChallenge: challenge,
			ExpiresAt:     time.Now().Add(claimTTL),
		}
		mu.Unlock()
		log.Printf("issued code=%s spn=%s redirect=%s", code, spn.ID, redirectURI)

		dest := redirectURI + "?" + url.Values{
			"code":  {code},
			"state": {state},
		}.Encode()
		http.Redirect(w, r, dest, http.StatusFound)
		return
	}

	renderSelect(w, q, "")
}

// handleClaim is the unauthenticated endpoint that swaps a one-time code for
// the wg config. PKCE proves the caller is the same client that started the
// flow. The code is single-use and short-lived, and we return the config as
// plain text (not JSON) so it goes straight to disk.
func handleClaim(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if err := r.ParseForm(); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	code := r.PostForm.Get("code")
	verifier := r.PostForm.Get("code_verifier")
	redirectURI := r.PostForm.Get("redirect_uri")

	mu.Lock()
	pc, ok := claims[code]
	if ok {
		delete(claims, code) // single-use even on failure to prevent enum
	}
	mu.Unlock()

	if !ok || time.Now().After(pc.ExpiresAt) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_grant"})
		return
	}
	if pc.RedirectURI != redirectURI {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_grant", "error_description": "redirect_uri mismatch"})
		return
	}
	if pkceS256(verifier) != pc.CodeChallenge {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_grant", "error_description": "code_verifier mismatch"})
		return
	}

	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	fmt.Fprint(w, pc.Conf)
}

func renderSelect(w http.ResponseWriter, q url.Values, errMsg string) {
	hidden := func(key string) string {
		return fmt.Sprintf(`<input type=hidden name=%s value=%q>`, key, q.Get(key))
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, `<!doctype html><meta charset=utf-8><title>Choose SPN — Cloudnetip</title>
<style>
body{font:16px/1.4 -apple-system,system-ui,sans-serif;max-width:480px;margin:60px auto;padding:0 20px}
h1{margin:0 0 8px}
.muted{color:#888;font-size:13px}
.err{color:#c0392b;margin:12px 0;padding:8px 12px;background:#fde8e6;border-radius:6px}
.row{display:block;padding:12px;border:1px solid #e0e0e0;border-radius:8px;margin:8px 0;cursor:pointer}
.row:hover{border-color:#0a84ff}
.row input{margin-right:10px}
.row .name{font-weight:600}
.row .meta{color:#888;font-size:13px}
input[type=text]{font:16px monospace;padding:8px;width:100%;box-sizing:border-box;border:1px solid #ccc;border-radius:6px}
button{font:16px sans-serif;padding:10px 28px;border:0;border-radius:6px;background:#0a84ff;color:#fff;cursor:pointer;margin-top:16px}
button:hover{background:#066dd6}
label.otp{display:block;margin:16px 0 4px}
</style>
<h1>Choose a network</h1>
<p class=muted>Pick the SPN to send to your device. Signed in as <b>oxmix@cloudnetip</b> (mock).</p>`)

	if errMsg != "" {
		fmt.Fprintf(w, `<div class=err>%s</div>`, htmlEscape(errMsg))
	}

	fmt.Fprint(w, `<form method=POST action="/api/spn/authorize">`)
	for k := range q {
		// Carry every original auth query param across as a hidden input.
		fmt.Fprint(w, hidden(k))
	}
	for i, s := range spns {
		checked := ""
		if i == 0 {
			checked = "checked"
		}
		fmt.Fprintf(w, `<label class=row><input type=radio name=spn_id value=%q %s>
<span class=name>%s</span><br><span class=meta>id: %s%s</span></label>`,
			s.ID, checked, htmlEscape(s.Name), s.ID,
			func() string {
				if s.RequiresOTP {
					return " · OTP required"
				}
				return ""
			}())
	}
	fmt.Fprint(w, `<label class=otp>One-time password (only for OTP-protected SPNs)</label>
<input type=text name=otp autocomplete=off>
<button type=submit>Send to device</button>
</form>`)
}

func findSPN(id string) *spnEntry {
	for i := range spns {
		if spns[i].ID == id {
			return &spns[i]
		}
	}
	return nil
}

const confProd = `[Interface]
PrivateKey = oN8VBnLDkMvVZ5e6yV2T2bH0gQjP0Yp+xX9JmL3aV2I=
Address = 10.66.66.2/32
DNS = 10.66.66.1

[Peer]
PublicKey = 1qX/D1Y7Y0gT0d3Bq3pqkLqgLJg1c7C1qV8jQq1J0Tg=
AllowedIPs = 10.66.66.0/24
Endpoint = vpn-prod.example.com:51820
PersistentKeepalive = 25
`

const confStaging = `[Interface]
PrivateKey = pY9WBnLDkMvVZ5e6yV2T2bH0gQjP0Yp+xX9JmL3aV2J=
Address = 10.77.77.2/32
DNS = 10.77.77.1

[Peer]
PublicKey = 2sY/D1Y7Y0gT0d3Bq3pqkLqgLJg1c7C1qV8jQq1J0Th=
AllowedIPs = 10.77.77.0/24
Endpoint = vpn-staging.example.com:51820
PersistentKeepalive = 25
`

const confDev = `[Interface]
PrivateKey = qZ0XBnLDkMvVZ5e6yV2T2bH0gQjP0Yp+xX9JmL3aV2K=
Address = 10.88.88.2/32
DNS = 10.88.88.1

[Peer]
PublicKey = 3tZ/D1Y7Y0gT0d3Bq3pqkLqgLJg1c7C1qV8jQq1J0Ti=
AllowedIPs = 10.88.88.0/24
Endpoint = vpn-dev.example.com:51820
PersistentKeepalive = 25
`

func isLoopbackRedirect(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "http" {
		return false
	}
	host := u.Hostname()
	return host == "127.0.0.1" || host == "::1" || host == "localhost"
}

func pkceS256(verifier string) string {
	if verifier == "" {
		return ""
	}
	sum := sha256.Sum256([]byte(verifier))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

func randomHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func htmlEscape(s string) string {
	r := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;", "'", "&#39;")
	return r.Replace(s)
}
