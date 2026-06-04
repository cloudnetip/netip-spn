package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"time"
)

const (
	defaultAPIBase  = "https://cloudnetip.com"
	userAgentPrefix = "netip-spn"

	pathAuthorize = "/app/shared/authorize"
	pathClaim     = "/api/spn/clients/config/claim"

	authTimeout = 5 * time.Minute
)

func apiBaseURL() string {
	if v := strings.TrimRight(os.Getenv("NETIP_API_URL"), "/"); v != "" {
		return v
	}
	return defaultAPIBase
}

func userAgent() string {
	return fmt.Sprintf("%s/%s (%s/%s)", userAgentPrefix, version, runtime.GOOS, runtime.GOARCH)
}

// cmdAuthLogin runs the loopback OAuth flow and writes the wg-quick config
// the server returned to ~/.cloudnetip/spn.conf. There is no persistent
// auth token: the config itself is the credential, and the user re-runs
// `auth login` to rotate or pick a different SPN.
func cmdAuthLogin() {
	base := apiBaseURL()
	fmt.Printf("Authenticating to Cloudnetip SPN\n")

	conf, err := runLoopbackAuth(base)
	if err != nil {
		fail("authentication failed: %v", err)
	}
	if !looksLikeWireGuardConfig(conf) {
		fail("server returned data that is not a WireGuard config")
	}

	dir := userConfigDir()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		fail("cannot create %s: %v", dir, err)
	}
	if err := os.WriteFile(userConfigPath(), conf, 0o600); err != nil {
		fail("cannot write config: %v", err)
	}
	fmt.Println("✓ Successful authentication, now run: netip-spn connect")
}

func cmdAuthLogout() {
	if err := os.Remove(userConfigPath()); err != nil && !os.IsNotExist(err) {
		fail("cannot remove %s: %v", userConfigPath(), err)
	}
	// wg-quick.conf is a derived file; remove it too so a stale copy is not
	// reused on the next `connect` after the user has signed out.
	_ = os.Remove(userWgConfigPath())
	fmt.Println("✓ Config removed.")
}

// runLoopbackAuth performs OAuth 2.0 authorization-code flow with PKCE
// (RFC 7636 + RFC 8252). The server's claim endpoint returns the wg config
// directly instead of a Bearer token, so this function returns config bytes.
func runLoopbackAuth(base string) ([]byte, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, fmt.Errorf("cannot bind loopback listener: %w", err)
	}
	defer ln.Close()

	port := ln.Addr().(*net.TCPAddr).Port
	redirectURI := fmt.Sprintf("http://127.0.0.1:%d/callback", port)

	state, err := randomURLSafe(24)
	if err != nil {
		return nil, err
	}
	verifier, err := randomURLSafe(48)
	if err != nil {
		return nil, err
	}
	challenge := pkceS256(verifier)

	authURL := base + pathAuthorize + "?" + url.Values{
		"response_type":         {"code"},
		"redirect_uri":          {redirectURI},
		"state":                 {state},
		"code_challenge":        {challenge},
		"code_challenge_method": {"S256"},
		"scope":                 {"spn"},
	}.Encode()

	type result struct {
		code string
		err  error
	}
	resultCh := make(chan result, 1)

	mux := http.NewServeMux()
	mux.HandleFunc("/callback", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		if e := q.Get("error"); e != "" {
			writeBrowserMessage(w, "Sign-in failed", e+": "+q.Get("error_description"))
			resultCh <- result{err: fmt.Errorf("%s: %s", e, q.Get("error_description"))}
			return
		}
		if q.Get("state") != state {
			writeBrowserMessage(w, "Sign-in failed", "state mismatch — possible CSRF, ignored")
			resultCh <- result{err: errors.New("state mismatch")}
			return
		}
		code := q.Get("code")
		if code == "" {
			writeBrowserMessage(w, "Sign-in failed", "no code in callback")
			resultCh <- result{err: errors.New("missing code")}
			return
		}
		writeBrowserMessage(w, "✓ Configured", "You can close this tab and return to the terminal.")
		resultCh <- result{code: code}
	})

	srv := &http.Server{Handler: mux}
	go srv.Serve(ln)
	defer srv.Shutdown(context.Background())

	fmt.Println("Opening browser to choose SPN account...")
	if err := openBrowser(authURL); err != nil {
		fmt.Fprintf(os.Stderr, "could not open browser: %v\n", err)
		fmt.Fprintf(os.Stderr, "open this URL manually:\n  %s\n", authURL)
	}

	select {
	case r := <-resultCh:
		if r.err != nil {
			return nil, r.err
		}
		return claimConfig(base, r.code, verifier, redirectURI)
	case <-time.After(authTimeout):
		return nil, fmt.Errorf("timed out after %s waiting for browser callback", authTimeout)
	}
}

func claimConfig(base, code, verifier, redirectURI string) ([]byte, error) {
	form := url.Values{}
	form.Set("code", code)
	form.Set("redirect_uri", redirectURI)
	form.Set("code_verifier", verifier)

	req, err := http.NewRequest(http.MethodPost, base+pathClaim, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "text/plain")
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("User-Agent", userAgent())

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	return body, nil
}

func openBrowser(target string) error {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", target)
	case "linux":
		cmd = exec.Command("xdg-open", target)
	default:
		return fmt.Errorf("unsupported OS: %s", runtime.GOOS)
	}
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	return cmd.Start()
}

func randomURLSafe(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

func pkceS256(verifier string) string {
	sum := sha256.Sum256([]byte(verifier))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

func writeBrowserMessage(w http.ResponseWriter, title, body string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, `<!doctype html><meta charset=utf-8><title>%s</title>
<style>body{font:16px/1.4 -apple-system,system-ui,sans-serif;max-width:520px;margin:80px auto;padding:0 20px;text-align:center}h1{margin-bottom:8px}</style>
<h1>%s</h1><p>%s</p>
<script>setTimeout(function(){window.close()},1500)</script>`,
		htmlEscapeStr(title), htmlEscapeStr(title), htmlEscapeStr(body))
}

func htmlEscapeStr(s string) string {
	r := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;")
	return r.Replace(s)
}
