// Package hub is chamberd's network surface: the /agent and /stream WebSocket
// endpoints (wire-compatible with the voice-chamber prototype so the existing
// web ?live page works unmodified), the /events HTTP adapter for non-MCP
// agents, and the management/debug endpoints. See docs/agent-bridge.md.
package hub

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/cfoust/chamber/chamberd/internal/input"
	"github.com/cfoust/chamber/chamberd/internal/registry"
	"github.com/cfoust/chamber/chamberd/internal/tts"
	"github.com/cfoust/chamber/chamberd/internal/voice"
)

// FIELD maps event type → the frame field its text travels in (prototype contract).
var FIELD = map[string]string{
	"task":     "headline",
	"progress": "note",
	"done":     "summary",
	"blocked":  "question",
}

type Hub struct {
	reg    *registry.Registry
	roster voice.Roster
	chain  *tts.Chain

	mu     sync.Mutex
	seats  []string // seat index → agent id ("" = free)
	pages  map[*conn]bool
	agents map[string]*conn // agent id → live socket

	upgrader websocket.Upgrader
}

// conn wraps a websocket with a write lock (gorilla conns are not concurrent-write safe).
type conn struct {
	ws *websocket.Conn
	wm sync.Mutex
	id string // agent id ("" for pages)
}

func (c *conn) send(v any) error {
	c.wm.Lock()
	defer c.wm.Unlock()
	return c.ws.WriteJSON(v)
}

func New(reg *registry.Registry, roster voice.Roster, chain *tts.Chain) *Hub {
	return &Hub{
		reg:    reg,
		roster: roster,
		chain:  chain,
		seats:  make([]string, len(roster.Personas)),
		pages:  map[*conn]bool{},
		agents: map[string]*conn{},
		// localhost-only bind; pages are file:// or vite dev servers
		upgrader: websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }},
	}
}

// Routes registers all endpoints on mux. audioDir is the TTS cache directory
// served at /audio/ (the native app streams lines from here instead of base64).
func (h *Hub) Routes(mux *http.ServeMux, audioDir string) {
	mux.HandleFunc("/agent", h.handleAgent)
	mux.HandleFunc("/stream", h.handleStream)
	mux.HandleFunc("/events", h.handleEvents)
	mux.HandleFunc("/agents", h.handleAgents)
	mux.HandleFunc("/agents/", h.handleAgentByID)
	mux.HandleFunc("/health", h.handleHealth)
	mux.HandleFunc("/debug/emit", h.handleDebugEmit)
	mux.Handle("/audio/", http.StripPrefix("/audio/", http.FileServer(http.Dir(audioDir))))
}

// ---- agent side ---------------------------------------------------------------

type agentHello struct {
	Type    string      `json:"type"`
	Session string      `json:"session"`
	Kind    string      `json:"kind"`
	Repo    string      `json:"repo"`
	Cwd     string      `json:"cwd"`
	Title   string      `json:"title"`
	Input   *input.Info `json:"input"` // talk-back target (tmux pane etc.)
}

type agentEvent struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

func (h *Hub) handleAgent(w http.ResponseWriter, r *http.Request) {
	ws, err := h.upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	c := &conn{ws: ws}

	// Identity handshake: the first message SHOULD be a hello. A legacy client
	// (prototype chamber-channel) sends a narration event first — give it an
	// anonymous identity so it still works.
	var first json.RawMessage
	if err := ws.ReadJSON(&first); err != nil {
		ws.Close()
		return
	}
	var hello agentHello
	_ = json.Unmarshal(first, &hello)
	var pendingEvent *agentEvent
	if hello.Type != "hello" {
		hello = agentHello{Session: fmt.Sprintf("anon-%s-%d", r.RemoteAddr, time.Now().UnixNano()), Kind: "unknown"}
		var ev agentEvent
		if json.Unmarshal(first, &ev) == nil && FIELD[ev.Type] != "" {
			pendingEvent = &ev
		}
	}

	rec := h.reg.Upsert(hello.Session, hello.Kind, hello.Repo, hello.Title)
	if hello.Input != nil {
		h.reg.SetInput(rec.ID, hello.Input.Kind, hello.Input.Target, hello.Input.Socket)
	}
	persona := h.bindPersona(rec.ID)
	seat := h.claimSeat(rec.ID, persona)

	c.id = rec.ID
	h.mu.Lock()
	if old, ok := h.agents[rec.ID]; ok {
		old.ws.Close() // a reconnect replaces the previous socket
	}
	h.agents[rec.ID] = c
	h.mu.Unlock()

	c.send(map[string]any{
		"type": "seat", "seat": seat, "color": persona.Color,
		"agent": rec.ID, "voice": persona.Name,
	})
	h.broadcast(map[string]any{
		"type": "bind", "seat": seat, "color": persona.Color,
		"agent": rec.ID, "name": persona.Name, "input": h.inputKind(rec.ID),
	})
	log.Printf("agent %s (%s, %s) bound to seat %d as %s (input: %s)",
		rec.ID, hello.Kind, hello.Repo, seat, persona.Name, orNone(h.inputKind(rec.ID)))

	if pendingEvent != nil {
		h.emit(rec.ID, seat, persona, pendingEvent.Type, pendingEvent.Text)
	}

	for {
		var ev agentEvent
		if err := ws.ReadJSON(&ev); err != nil {
			break
		}
		if FIELD[ev.Type] == "" {
			h.reg.Touch(rec.ID, false) // traffic, but not a narration event
			continue
		}
		h.emit(rec.ID, seat, persona, ev.Type, ev.Text)
	}

	// disconnect: free the seat, keep the registry record (identity survives)
	h.mu.Lock()
	if h.agents[rec.ID] == c {
		delete(h.agents, rec.ID)
	}
	freed := h.freeSeatLocked(rec.ID)
	h.mu.Unlock()
	if freed >= 0 {
		h.broadcast(map[string]any{"type": "free", "seat": freed, "agent": rec.ID})
	}
	ws.Close()
}

// bindPersona gives the record its sticky persona (existing binding wins).
func (h *Hub) bindPersona(id string) voice.Persona {
	rec, _ := h.reg.Get(id)
	name := rec.Voice
	if name == "" {
		name = h.roster.Pick(h.reg.VoicesInUse()).Name
	}
	name = h.reg.BindVoice(id, name)
	p, ok := h.roster.Get(name)
	if !ok {
		p = h.roster.Personas[0]
	}
	return p
}

// claimSeat prefers the persona's home seat, then any free seat, then steals
// the seat whose occupant has been quiet longest.
func (h *Hub) claimSeat(id string, persona voice.Persona) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	for i, occupant := range h.seats {
		if occupant == id {
			return i
		}
	}
	if home := h.roster.Seat(persona.Name); home >= 0 && h.seats[home] == "" {
		h.seats[home] = id
		return home
	}
	for i, occupant := range h.seats {
		if occupant == "" {
			h.seats[i] = id
			return i
		}
	}
	steal, oldest := 0, time.Now()
	for i, occupant := range h.seats {
		if rec, ok := h.reg.Get(occupant); ok && rec.LastEventAt.Before(oldest) {
			steal, oldest = i, rec.LastEventAt
		}
	}
	h.seats[steal] = id
	return steal
}

func (h *Hub) freeSeatLocked(id string) int {
	for i, occupant := range h.seats {
		if occupant == id {
			h.seats[i] = ""
			return i
		}
	}
	return -1
}

// emit builds a narration frame — synthesizing the voice line via the TTS
// ladder — and broadcasts it to every chamber client.
func (h *Hub) emit(agentID string, seat int, persona voice.Persona, typ, text string) {
	h.reg.Touch(agentID, true)
	if typ == "task" {
		h.reg.SetTitle(agentID, text)
	}
	frame := map[string]any{
		"type": typ, "seat": seat, "color": persona.Color,
		"agent": agentID, "name": persona.Name,
		FIELD[typ]: text,
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	res, err := h.chain.Speak(ctx, persona, text, typ == "progress")
	if err == nil {
		if b, rerr := os.ReadFile(res.Path); rerr == nil {
			frame["audioB64"] = base64.StdEncoding.EncodeToString(b)
			frame["audioUrl"] = "/audio/" + filepath.Base(res.Path)
			frame["degraded"] = res.Degraded
		}
	} else if err != tts.ErrSilent {
		log.Printf("tts: %v", err)
	}
	h.broadcast(frame)
}

func (h *Hub) broadcast(frame map[string]any) {
	h.mu.Lock()
	targets := make([]*conn, 0, len(h.pages))
	for p := range h.pages {
		targets = append(targets, p)
	}
	h.mu.Unlock()
	for _, p := range targets {
		if err := p.send(frame); err != nil {
			h.mu.Lock()
			delete(h.pages, p)
			h.mu.Unlock()
			p.ws.Close()
		}
	}
}

// ---- chamber-client side --------------------------------------------------------

func (h *Hub) handleStream(w http.ResponseWriter, r *http.Request) {
	ws, err := h.upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	c := &conn{ws: ws}
	h.mu.Lock()
	h.pages[c] = true
	seats := make([]map[string]any, len(h.seats))
	for i := range h.seats {
		seats[i] = map[string]any{"seat": i, "color": h.roster.Personas[i].Color}
	}
	h.mu.Unlock()
	c.send(map[string]any{"type": "hello", "seats": seats})

	for {
		var msg struct {
			Type string `json:"type"`
			Seat int    `json:"seat"`
			Text string `json:"text"`
		}
		if err := ws.ReadJSON(&msg); err != nil {
			break
		}
		if msg.Type != "say" || msg.Text == "" {
			continue
		}
		h.mu.Lock()
		var id string
		if msg.Seat >= 0 && msg.Seat < len(h.seats) {
			id = h.seats[msg.Seat]
		}
		h.mu.Unlock()
		if id == "" {
			log.Printf("say → seat %d: no agent", msg.Seat)
			continue
		}
		go h.deliverSay(id, msg.Text)
	}
	h.mu.Lock()
	delete(h.pages, c)
	h.mu.Unlock()
	ws.Close()
}

// deliverSay routes the user's words into an agent. Multiplexer injection
// first — it is generic (works for any agent kind, connected or not) and
// user-visible as ordinary typed input. The MCP channel notification is the
// fallback for socket-connected agents outside a known pane. A dead pane
// clears the stored target so reachability reporting stays honest.
func (h *Hub) deliverSay(id, text string) {
	rec, ok := h.reg.Get(id)
	if !ok {
		return
	}
	if rec.InputKind != "" {
		inj := input.Info{Kind: rec.InputKind, Target: rec.InputTarget, Socket: rec.InputSocket}
		if err := inj.Inject(text); err == nil {
			return
		} else {
			log.Printf("say → %s: %s injection failed (%v), clearing target", id, rec.InputKind, err)
			h.reg.SetInput(id, "", "", "")
		}
	}
	h.mu.Lock()
	target := h.agents[id]
	h.mu.Unlock()
	if target != nil {
		target.send(map[string]any{"type": "channel", "text": text})
		return
	}
	log.Printf("say → %s: unreachable (no input target, not connected)", id)
}

// inputKind reports how (whether) an agent can receive talk-back:
// its mux target kind, "channel" when only the socket path exists, "" = none.
func (h *Hub) inputKind(id string) string {
	rec, ok := h.reg.Get(id)
	if ok && rec.InputKind != "" {
		return rec.InputKind
	}
	h.mu.Lock()
	_, connected := h.agents[id]
	h.mu.Unlock()
	if connected {
		return "channel"
	}
	return ""
}

func orNone(s string) string {
	if s == "" {
		return "none"
	}
	return s
}

// ---- HTTP surfaces ---------------------------------------------------------------

// handleEvents is the curl-simple adapter for agents without an MCP channel:
// POST {"session","kind","repo","title","type","text"}.
func (h *Hub) handleEvents(w http.ResponseWriter, r *http.Request) {
	cors(w)
	if r.Method == http.MethodOptions {
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var ev struct {
		agentHello
		EventType string `json:"type"`
		Text      string `json:"text"`
	}
	if err := json.NewDecoder(r.Body).Decode(&ev); err != nil || ev.Session == "" || FIELD[ev.EventType] == "" {
		http.Error(w, "bad event", http.StatusBadRequest)
		return
	}
	rec := h.reg.Upsert(ev.Session, ev.Kind, ev.Repo, ev.Title)
	if ev.Input != nil {
		h.reg.SetInput(rec.ID, ev.Input.Kind, ev.Input.Target, ev.Input.Socket)
	}
	persona := h.bindPersona(rec.ID)
	seat := h.claimSeat(rec.ID, persona)
	h.emit(rec.ID, seat, persona, ev.EventType, ev.Text)
	json.NewEncoder(w).Encode(map[string]any{"ok": true, "agent": rec.ID, "seat": seat})
}

// handleAgents is the management list: GET /agents.
func (h *Hub) handleAgents(w http.ResponseWriter, r *http.Request) {
	cors(w)
	type row struct {
		registry.Record
		Connected bool   `json:"connected"`
		Seat      int    `json:"seat"`
		Input     string `json:"input"` // talk-back capability kind; "" = unreachable
	}
	h.mu.Lock()
	seatOf := map[string]int{}
	for i, id := range h.seats {
		if id != "" {
			seatOf[id] = i
		}
	}
	connected := map[string]bool{}
	for id := range h.agents {
		connected[id] = true
	}
	h.mu.Unlock()
	rows := []row{}
	for _, rec := range h.reg.List() {
		seat, ok := seatOf[rec.ID]
		if !ok {
			seat = -1
		}
		rows = append(rows, row{Record: rec, Connected: connected[rec.ID], Seat: seat, Input: h.inputKind(rec.ID)})
	}
	w.Header().Set("content-type", "application/json")
	json.NewEncoder(w).Encode(rows)
}

// handleAgentByID: DELETE /agents/{id} evicts a record and frees its seat.
func (h *Hub) handleAgentByID(w http.ResponseWriter, r *http.Request) {
	cors(w)
	if r.Method != http.MethodDelete {
		http.Error(w, "DELETE only", http.StatusMethodNotAllowed)
		return
	}
	id := strings.TrimPrefix(r.URL.Path, "/agents/")
	h.mu.Lock()
	if c, ok := h.agents[id]; ok {
		c.ws.Close()
		delete(h.agents, id)
	}
	freed := h.freeSeatLocked(id)
	h.mu.Unlock()
	if freed >= 0 {
		h.broadcast(map[string]any{"type": "free", "seat": freed, "agent": id})
	}
	if !h.reg.Evict(id) {
		http.Error(w, "no such agent", http.StatusNotFound)
		return
	}
	json.NewEncoder(w).Encode(map[string]any{"ok": true})
}

func (h *Hub) handleHealth(w http.ResponseWriter, _ *http.Request) {
	cors(w)
	h.mu.Lock()
	occupied := []int{}
	for i, id := range h.seats {
		if id != "" {
			occupied = append(occupied, i)
		}
	}
	h.mu.Unlock()
	w.Header().Set("content-type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"ok": true, "agents": occupied})
}

// handleDebugEmit drives frames with no session (the mock/test harness):
// POST {"seat"?, "type"?, "text"?}. bind/free are broadcast as-is.
func (h *Hub) handleDebugEmit(w http.ResponseWriter, r *http.Request) {
	cors(w)
	if r.Method == http.MethodOptions {
		return
	}
	var msg struct {
		Seat int    `json:"seat"`
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if err := json.NewDecoder(r.Body).Decode(&msg); err != nil {
		http.Error(w, "bad body", http.StatusBadRequest)
		return
	}
	if msg.Seat < 0 || msg.Seat >= len(h.roster.Personas) {
		msg.Seat = 0
	}
	persona := h.roster.Personas[msg.Seat]
	switch msg.Type {
	case "bind", "free":
		h.broadcast(map[string]any{"type": msg.Type, "seat": msg.Seat, "color": persona.Color})
	default:
		if FIELD[msg.Type] == "" {
			http.Error(w, "bad type", http.StatusBadRequest)
			return
		}
		rec := h.reg.Upsert("debug-seat-"+fmt.Sprint(msg.Seat), "debug", "", "")
		h.reg.BindVoice(rec.ID, persona.Name)
		h.emit(rec.ID, msg.Seat, persona, msg.Type, msg.Text)
	}
	json.NewEncoder(w).Encode(map[string]any{"ok": true})
}

func cors(w http.ResponseWriter) {
	h := w.Header()
	h.Set("access-control-allow-origin", "*")
	h.Set("access-control-allow-methods", "GET, POST, DELETE, OPTIONS")
	h.Set("access-control-allow-headers", "content-type")
}
