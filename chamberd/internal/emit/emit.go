// Package emit is `chamberd emit`: the universal, zero-integration agent
// surface. Any coding agent that can run a command is integrated:
//
//	chamberd emit -type task -text "reworking the auth flow"
//	chamberd emit -type done -text "Tests pass; the flow uses refresh tokens now."
//
// It resolves the hub from the discovery file (~/.chamber/chamberd.json), so
// "hub not running" costs one stat() — and it is fail-open end to end: hard
// timeouts, always exit 0, never a byte on stdout. An agent's hooks can call
// this unconditionally without ever affecting the session.
package emit

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/cfoust/chamber/chamberd/internal/input"
)

const timeout = 500 * time.Millisecond

// Run sends one event and always returns 0. All diagnostics go to stderr.
func Run(args []string) int {
	var typ, text, session, kind, stateDir string
	// tiny hand-rolled flag walk: flag.ExitOnError would violate fail-open
	for i := 0; i < len(args); i++ {
		next := func() string {
			if i+1 < len(args) {
				i++
				return args[i]
			}
			return ""
		}
		switch args[i] {
		case "-type", "--type":
			typ = next()
		case "-text", "--text":
			text = next()
		case "-session", "--session":
			session = next()
		case "-kind", "--kind":
			kind = next()
		case "-state", "--state":
			stateDir = next()
		}
	}
	if typ == "" || text == "" {
		fmt.Fprintln(os.Stderr, "usage: chamberd emit -type task|progress|done|blocked -text \"…\" [-session id] [-kind name]")
		return 0 // fail-open even for misuse: never break a hook pipeline
	}
	if session == "" {
		session = os.Getenv("CHAMBER_SESSION")
	}
	if session == "" {
		session = fmt.Sprintf("ppid-%d-%s", os.Getppid(), repoName())
	}
	if kind == "" {
		kind = os.Getenv("CHAMBER_KIND")
	}
	if kind == "" {
		kind = "cli"
	}

	port, ok := discoverPort(stateDir)
	if !ok {
		return 0 // hub not running: silently do nothing
	}
	payload := map[string]any{
		"session": session,
		"kind":    kind,
		"repo":    repoName(),
		"type":    typ,
		"text":    text,
	}
	if inp := input.Detect(); inp != nil {
		payload["input"] = inp // talk-back target: hooks inherit the mux env
	}
	body, _ := json.Marshal(payload)
	client := &http.Client{Timeout: timeout}
	resp, err := client.Post(
		fmt.Sprintf("http://127.0.0.1:%d/events", port),
		"application/json",
		bytes.NewReader(body),
	)
	if err == nil {
		resp.Body.Close()
	}
	return 0
}

// discoverPort reads the daemon's discovery file; a missing/stale file means
// "not running" without touching the network.
func discoverPort(stateDir string) (int, bool) {
	if stateDir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return 0, false
		}
		stateDir = filepath.Join(home, ".chamber")
	}
	b, err := os.ReadFile(filepath.Join(stateDir, "chamberd.json"))
	if err != nil {
		return 0, false
	}
	var d struct {
		Port int `json:"port"`
		Pid  int `json:"pid"`
	}
	if json.Unmarshal(b, &d) != nil || d.Port == 0 {
		return 0, false
	}
	if d.Pid > 0 {
		if p, err := os.FindProcess(d.Pid); err != nil || p.Signal(syscall.Signal(0)) != nil {
			return 0, false // stale file from an unclean shutdown
		}
	}
	return d.Port, true
}

func repoName() string {
	out, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
	if err == nil {
		if top := strings.TrimSpace(string(out)); top != "" {
			return filepath.Base(top)
		}
	}
	d, err := os.Getwd()
	if err != nil {
		return "unknown"
	}
	return filepath.Base(d)
}
