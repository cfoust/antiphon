// Package channel is `chamberd channel`: the per-session MCP server Claude
// Code spawns over stdio. It exposes the four narration tools, relays them to
// the hub's /agent WebSocket, and injects hub "channel" messages (talk-back)
// into the session as MCP notifications.
//
// The fail-open contract lives here: the hub being down must cost the session
// nothing. Dials have a hard 250 ms timeout, reconnects back off with jitter,
// tool calls ALWAYS return "ok" instantly, and narration during an outage is
// dropped — except the latest done-summary, which is buffered (depth one) and
// delivered on reconnect because it's the line with durable value.
package channel

import (
	"bufio"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/cfoust/chamber/chamberd/internal/input"
)

const (
	dialTimeout  = 250 * time.Millisecond
	retryMin     = time.Second
	retryMax     = 30 * time.Second
	protocolVers = "2024-11-05"
)

// instructions are injected into Claude's system prompt by the MCP handshake.
const instructions = `You are connected to Chamber, a spatial-audio monitor where the user
HEARS you as a voice in a room. Narrate your work through it, always in first person,
always short enough to speak aloud:
- chamber_task when you begin something new (one headline).
- chamber_progress every few tool calls (a few words, present tense).
- chamber_done when you finish (1-2 spoken sentences: what changed, where).
- chamber_blocked when you need the user (one clear question).
Messages arriving in <channel source="chamber"> tags are the user speaking to you
from the room; treat them as user input.`

type tool struct {
	name, desc, arg, argDesc, typ string
}

var tools = []tool{
	{"chamber_task", "Announce the task you are starting.", "headline", "One short headline, spoken aloud.", "task"},
	{"chamber_progress", "Report what you are doing right now.", "note", "A few words, present tense.", "progress"},
	{"chamber_done", "Report that you finished.", "summary", "1-2 spoken sentences summarizing the outcome.", "done"},
	{"chamber_blocked", "Ask the user a question you are blocked on.", "question", "One clear question.", "blocked"},
}

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type event struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

// Channel is one session's bridge instance.
type Channel struct {
	hubURL  string
	session string
	repo    string

	outMu sync.Mutex
	out   *json.Encoder

	hubMu       sync.Mutex
	hub         *websocket.Conn
	pendingDone *event // buffer of one: the latest done-summary
	pendingAt   time.Time
	seat        int
}

// A done-summary this recent is replayed on reconnect. Writes to a just-died
// socket "succeed" locally (the RST arrives later), so we can't know whether a
// line was delivered — we always buffer the latest done and replay it if the
// connection turns over soon after. A rare duplicate re-announcement beats a
// lost summary.
const doneReplayTTL = 5 * time.Minute

// New builds a channel. hubURL "" uses CHAMBER_HUB or the default port.
func New(hubURL string) *Channel {
	if hubURL == "" {
		hubURL = os.Getenv("CHAMBER_HUB")
	}
	if hubURL == "" {
		hubURL = "ws://127.0.0.1:8787/agent"
	}
	return &Channel{
		hubURL:  hubURL,
		session: sessionID(),
		repo:    repoName(),
		seat:    -1,
	}
}

// Run serves MCP over rw (stdin/stdout) until EOF. Never returns an error for
// hub trouble — only for a broken stdio transport.
func (c *Channel) Run(in io.Reader, out io.Writer) error {
	c.out = json.NewEncoder(out)
	go c.hubLoop()

	sc := bufio.NewScanner(in)
	sc.Buffer(make([]byte, 0, 1<<20), 1<<24) // long tool args
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var req rpcRequest
		if err := json.Unmarshal(line, &req); err != nil {
			continue // not ours to crash over
		}
		c.dispatch(req)
	}
	return sc.Err()
}

func (c *Channel) dispatch(req rpcRequest) {
	switch req.Method {
	case "initialize":
		c.reply(req.ID, map[string]any{
			"protocolVersion": protocolVers,
			"capabilities": map[string]any{
				"tools":        map[string]any{},
				"experimental": map[string]any{"claude/channel": map[string]any{}},
			},
			"serverInfo":   map[string]any{"name": "chamber", "version": "0.1.0"},
			"instructions": instructions,
		})
	case "notifications/initialized", "notifications/cancelled":
		// no reply to notifications
	case "ping":
		c.reply(req.ID, map[string]any{})
	case "tools/list":
		list := make([]map[string]any, len(tools))
		for i, t := range tools {
			list[i] = map[string]any{
				"name":        t.name,
				"description": t.desc,
				"inputSchema": map[string]any{
					"type":       "object",
					"properties": map[string]any{t.arg: map[string]any{"type": "string", "description": t.argDesc}},
					"required":   []string{t.arg},
				},
			}
		}
		c.reply(req.ID, map[string]any{"tools": list})
	case "tools/call":
		var p struct {
			Name string                     `json:"name"`
			Args map[string]json.RawMessage `json:"arguments"`
		}
		_ = json.Unmarshal(req.Params, &p)
		for _, t := range tools {
			if t.name != p.Name {
				continue
			}
			var text string
			_ = json.Unmarshal(p.Args[t.arg], &text)
			if text != "" {
				c.toHub(event{Type: t.typ, Text: text})
			}
			break
		}
		// ALWAYS ok, instantly — hub trouble never surfaces to the model
		c.reply(req.ID, map[string]any{"content": []map[string]any{{"type": "text", "text": "ok"}}})
	default:
		if req.ID != nil {
			c.rpcError(req.ID, -32601, "method not found")
		}
	}
}

func (c *Channel) reply(id json.RawMessage, result any) {
	if id == nil {
		return
	}
	c.write(map[string]any{"jsonrpc": "2.0", "id": id, "result": result})
}

func (c *Channel) rpcError(id json.RawMessage, code int, msg string) {
	c.write(map[string]any{"jsonrpc": "2.0", "id": id, "error": map[string]any{"code": code, "message": msg}})
}

func (c *Channel) notify(method string, params any) {
	c.write(map[string]any{"jsonrpc": "2.0", "method": method, "params": params})
}

func (c *Channel) write(v any) {
	c.outMu.Lock()
	defer c.outMu.Unlock()
	_ = c.out.Encode(v) // Encode appends the newline stdio framing needs
}

// ---- hub side -------------------------------------------------------------------

// toHub relays an event if connected. Blips during an outage are dropped
// (ephemeral by definition); the latest done-summary is always buffered so a
// connection turnover can't eat it (see doneReplayTTL).
func (c *Channel) toHub(ev event) {
	c.hubMu.Lock()
	ws := c.hub
	if ev.Type == "done" {
		pending := ev
		c.pendingDone = &pending
		c.pendingAt = time.Now()
	}
	c.hubMu.Unlock()
	if ws == nil {
		return
	}
	if err := ws.WriteJSON(ev); err != nil {
		log.Printf("hub write failed: %v", err)
	}
}

// hubLoop maintains the hub connection forever: fast dial, capped backoff with
// jitter, identity hello on every (re)connect, flush of the buffered summary.
func (c *Channel) hubLoop() {
	delay := retryMin
	for {
		ws, err := c.dial()
		if err != nil {
			time.Sleep(jitter(delay))
			if delay *= 2; delay > retryMax {
				delay = retryMax
			}
			continue
		}
		delay = retryMin
		log.Printf("connected to hub %s", c.hubURL)

		hello := map[string]any{
			"type": "hello", "session": c.session, "kind": "claude-code",
			"repo": c.repo, "cwd": cwd(),
		}
		if inp := input.Detect(); inp != nil {
			hello["input"] = inp // talk-back target (tmux pane etc.)
		}
		ws.WriteJSON(hello)
		c.hubMu.Lock()
		c.hub = ws
		var pending *event
		if c.pendingDone != nil && time.Since(c.pendingAt) < doneReplayTTL {
			pending = c.pendingDone
		}
		c.pendingDone = nil
		c.hubMu.Unlock()
		if pending != nil {
			ws.WriteJSON(pending)
		}

		for {
			var msg struct {
				Type string          `json:"type"`
				Seat json.RawMessage `json:"seat"`
				Text string          `json:"text"`
			}
			if err := ws.ReadJSON(&msg); err != nil {
				break
			}
			switch msg.Type {
			case "seat":
				var seat int
				_ = json.Unmarshal(msg.Seat, &seat)
				c.hubMu.Lock()
				c.seat = seat
				c.hubMu.Unlock()
			case "channel":
				// the user spoke to this agent from the chamber
				c.hubMu.Lock()
				seat := c.seat
				c.hubMu.Unlock()
				c.notify("notifications/claude/channel", map[string]any{
					"content": msg.Text,
					"meta":    map[string]any{"seat": fmt.Sprint(seat)},
				})
			}
		}

		c.hubMu.Lock()
		c.hub = nil
		c.hubMu.Unlock()
		ws.Close()
	}
}

func (c *Channel) dial() (*websocket.Conn, error) {
	d := websocket.Dialer{
		NetDialContext:   (&net.Dialer{Timeout: dialTimeout}).DialContext,
		HandshakeTimeout: dialTimeout * 4,
	}
	ws, _, err := d.Dial(c.hubURL, nil)
	return ws, err
}

func jitter(d time.Duration) time.Duration {
	n, err := rand.Int(rand.Reader, big.NewInt(int64(d)/2))
	if err != nil {
		return d
	}
	return d/2 + time.Duration(n.Int64())
}

// ---- identity -------------------------------------------------------------------

// sessionID prefers an explicit id (env) so reconnects reclaim the same
// registry record; otherwise it derives a stable one from the parent process
// (the agent that spawned us) + cwd, so channel restarts within one session —
// headless Claude restarts the MCP server — keep their identity and voice.
func sessionID() string {
	for _, k := range []string{"CHAMBER_SESSION", "CLAUDE_SESSION_ID", "CLAUDE_CODE_SESSION_ID"} {
		if v := os.Getenv(k); v != "" {
			return v
		}
	}
	return fmt.Sprintf("ppid-%d-%s", os.Getppid(), cwdHash())
}

func cwdHash() string {
	h := sha256.Sum256([]byte(cwd()))
	return hex.EncodeToString(h[:])[:8]
}

func repoName() string {
	out, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
	if err == nil {
		if top := strings.TrimSpace(string(out)); top != "" {
			return filepath.Base(top)
		}
	}
	return filepath.Base(cwd())
}

func cwd() string {
	d, err := os.Getwd()
	if err != nil {
		return ""
	}
	return d
}
