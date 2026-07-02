// Package input is the generic talk-back path: delivering the user's words
// INTO an agent by typing into the terminal pane it lives in. Any subprocess
// of the agent (chamberd channel, a hook running chamberd emit) inherits the
// multiplexer's environment, so it can report a durable "where I live" target
// that works for every agent kind — no per-agent protocol needed.
//
// tmux is implemented (TMUX_PANE + send-keys). cy is detected (the CY socket
// env) but injection is a TODO seam — same Info shape, different injector.
package input

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

// Info names an input target. Persisted on the agent's registry record, so
// even an emit-only (hook-level) integration can receive talk-back.
//
// Kinds form a quality ladder, best first:
//   - "http": the agent has a real programmatic API (OpenCode, aider, pi …);
//     Target is a URL that accepts POST {"text": "..."}. Agents whose native
//     API differs report a tiny local shim URL instead.
//   - "tmux" / "cy": the generic floor — type into the pane the agent lives
//     in. Works for ANY agent, discovered automatically from the environment
//     by chamberd channel / chamberd emit.
type Info struct {
	Kind   string `json:"kind"`             // "http" | "tmux" | "cy"
	Target string `json:"target"`           // http: URL · tmux: pane id ("%12")
	Socket string `json:"socket,omitempty"` // tmux: server socket path
}

// Detect reads the calling process's environment. Returns nil when the
// process isn't inside a supported multiplexer.
func Detect() *Info {
	if pane := os.Getenv("TMUX_PANE"); pane != "" {
		info := &Info{Kind: "tmux", Target: pane}
		// $TMUX = "socketpath,pid,sessionindex"
		if t := os.Getenv("TMUX"); t != "" {
			if i := strings.IndexByte(t, ','); i > 0 {
				info.Socket = t[:i]
			}
		}
		return info
	}
	if sock := os.Getenv("CY"); sock != "" {
		return &Info{Kind: "cy", Target: sock}
	}
	return nil
}

// Inject delivers text to the agent. For mux kinds it types text + Enter into
// the pane — text sent literally (-l) so tmux key names can't be interpreted,
// Enter as a separate key. Errors mean the target is gone — callers should
// treat that as "input no longer available".
func (i *Info) Inject(text string) error {
	switch i.Kind {
	case "http":
		body, _ := json.Marshal(map[string]string{"text": text})
		client := &http.Client{Timeout: 2 * time.Second}
		resp, err := client.Post(i.Target, "application/json", bytes.NewReader(body))
		if err != nil {
			return fmt.Errorf("http input: %w", err)
		}
		defer resp.Body.Close()
		if resp.StatusCode >= 300 {
			return fmt.Errorf("http input: %s", resp.Status)
		}
		return nil
	case "tmux":
		args := []string{}
		if i.Socket != "" {
			args = append(args, "-S", i.Socket)
		}
		send := append(args, "send-keys", "-t", i.Target, "-l", "--", text)
		if out, err := command("tmux", send...); err != nil {
			return fmt.Errorf("tmux send-keys: %w (%s)", err, out)
		}
		enter := append(args, "send-keys", "-t", i.Target, "Enter")
		if out, err := command("tmux", enter...); err != nil {
			return fmt.Errorf("tmux Enter: %w (%s)", err, out)
		}
		return nil
	case "cy":
		return fmt.Errorf("cy injection not implemented yet")
	default:
		return fmt.Errorf("unknown input kind %q", i.Kind)
	}
}

func command(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	done := make(chan struct{})
	var out []byte
	var err error
	go func() {
		out, err = cmd.CombinedOutput()
		close(done)
	}()
	select {
	case <-done:
		return strings.TrimSpace(string(out)), err
	case <-time.After(2 * time.Second):
		_ = cmd.Process.Kill()
		return "", fmt.Errorf("timed out")
	}
}
