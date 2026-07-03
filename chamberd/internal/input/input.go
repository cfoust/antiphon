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
	"path/filepath"
	"strconv"
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
	if v := os.Getenv("CY"); v != "" {
		// CY = "<socket>(:<node-id>)?" — only a pane context (id present) is a
		// typeable target; a socket-only CY (e.g. `cy exec` children) is not.
		if i := strings.IndexByte(v, ':'); i > 0 {
			return &Info{Kind: "cy", Socket: v[:i], Target: v[i+1:]}
		}
		return nil
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
		tmux := binPath("tmux")
		args := []string{}
		if i.Socket != "" {
			args = append(args, "-S", i.Socket)
		}
		// tmux 3.4 correctly prefers an explicit -S over $TMUX (verified), but strip
		// the mux env anyway so a socketless record can't resolve to whatever session
		// the daemon itself happens to live in. Same defense as the cy case.
		env := muxFreeEnv("TMUX=", "TMUX_PANE=")
		send := append(args, "send-keys", "-t", i.Target, "-l", "--", text)
		if out, err := command(env, tmux, send...); err != nil {
			return fmt.Errorf("tmux send-keys: %w (%s)", err, out)
		}
		enter := append(args, "send-keys", "-t", i.Target, "Enter")
		if out, err := command(env, tmux, enter...); err != nil {
			return fmt.Errorf("tmux Enter: %w (%s)", err, out)
		}
		return nil
	case "cy":
		// (pane/send-text id "…") types the text; (pane/send-keys id @["enter"])
		// submits it — delivered via `cy exec` against the agent's socket. The id
		// must be numeric (it crosses the wire from agents; no Janet injection).
		if _, err := strconv.Atoi(i.Target); err != nil {
			return fmt.Errorf("cy: bad pane id %q", i.Target)
		}
		code := fmt.Sprintf(`(pane/send-text %s %s)(pane/send-keys %s @["enter"])`,
			i.Target, janetString(text), i.Target)
		args := []string{"exec", "-c", code}
		if i.Socket != "" {
			args = append([]string{"-L", i.Socket}, args...)
		}
		// strip our own $CY: cy's CLI prefers env context OVER the explicit socket
		// flag (see cy repo: BUG-env-overrides-socket-flag.md)
		if out, err := command(muxFreeEnv("CY="), binPath("cy"), args...); err != nil {
			return fmt.Errorf("cy exec: %w (%s)", err, out)
		}
		return nil
	default:
		return fmt.Errorf("unknown input kind %q", i.Kind)
	}
}

// binPath resolves a mux binary: $PATH first, then the usual homes. A daemon
// spawned by the .app inherits the minimal GUI PATH (/usr/bin:/bin:…), which
// has neither homebrew nor ~/go/bin — where tmux and cy actually live.
func binPath(name string) string {
	if p, err := exec.LookPath(name); err == nil {
		return p
	}
	home, _ := os.UserHomeDir()
	for _, dir := range []string{
		"/opt/homebrew/bin", "/usr/local/bin",
		filepath.Join(home, "go", "bin"),
		filepath.Join(home, ".local", "bin"),
		filepath.Join(home, "bin"),
	} {
		p := filepath.Join(dir, name)
		if info, err := os.Stat(p); err == nil && !info.IsDir() && info.Mode()&0111 != 0 {
			return p
		}
	}
	return name // let exec fail with its own clear error
}

// muxFreeEnv is the current environment minus variables with the given prefixes —
// injection targets must come from the agent's record, never from wherever the
// daemon itself happens to be running.
func muxFreeEnv(prefixes ...string) []string {
	env := []string{}
	for _, e := range os.Environ() {
		keep := true
		for _, p := range prefixes {
			if strings.HasPrefix(e, p) {
				keep = false
				break
			}
		}
		if keep {
			env = append(env, e)
		}
	}
	return env
}

// janetString renders text as a Janet string literal.
func janetString(s string) string {
	r := strings.NewReplacer("\\", "\\\\", "\"", "\\\"", "\n", "\\n", "\r", "\\r", "\t", "\\t")
	return "\"" + r.Replace(s) + "\""
}

func command(env []string, name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	if env != nil {
		cmd.Env = env
	}
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
