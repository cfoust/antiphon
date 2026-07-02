// Package registry is chamberd's source of truth about agents: who has ever
// connected, what voice persona they're bound to, and when we last heard from
// them. Records persist to a JSON state file so identity (and therefore voice
// consistency) survives daemon restarts. Liveness is deliberately NOT stored:
// a connected socket doesn't prove the driver behind it is alive, so we keep
// timestamps (last_seen vs last_event) and let clients derive state.
package registry

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// Record is one agent's durable identity.
type Record struct {
	ID      string `json:"id"`      // short stable id derived from the session key
	Session string `json:"session"` // caller-provided session key (uuid, socket path, …)
	Kind    string `json:"kind"`    // "claude-code", "opencode", "debug", …
	Repo    string `json:"repo"`
	Title   string `json:"title"`
	Voice   string `json:"voice"` // persona name; sticky for the record's lifetime

	// Talk-back target (see internal/input): where typed text can reach this
	// agent. Persisted — an emit-only agent in a known pane stays reachable.
	InputKind   string `json:"input_kind,omitempty"`
	InputTarget string `json:"input_target,omitempty"`
	InputSocket string `json:"input_socket,omitempty"`

	CreatedAt   time.Time `json:"created_at"`
	LastSeenAt  time.Time `json:"last_seen_at"`  // any traffic (connect, ping)
	LastEventAt time.Time `json:"last_event_at"` // last meaningful narration event
}

// Registry is a mutex-guarded record store with atomic JSON persistence.
type Registry struct {
	mu   sync.Mutex
	path string // "" = in-memory only (tests)
	recs map[string]*Record
	Now  func() time.Time // injectable clock for tests
}

// Open loads (or initializes) a registry at path. Empty path = memory only.
func Open(path string) (*Registry, error) {
	r := &Registry{path: path, recs: map[string]*Record{}, Now: time.Now}
	if path == "" {
		return r, nil
	}
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return r, nil
	}
	if err != nil {
		return nil, err
	}
	var recs []*Record
	if err := json.Unmarshal(b, &recs); err != nil {
		return nil, err
	}
	for _, rec := range recs {
		r.recs[rec.ID] = rec
	}
	return r, nil
}

func idFor(session string) string {
	h := sha256.Sum256([]byte(session))
	return hex.EncodeToString(h[:])[:8]
}

// Upsert registers (or reclaims, keyed by session) an agent record. A reclaim
// keeps the record's id, voice binding and created_at — that IS the voice-
// consistency guarantee across reconnects and daemon restarts.
func (r *Registry) Upsert(session, kind, repo, title string) *Record {
	r.mu.Lock()
	defer r.mu.Unlock()
	id := idFor(session)
	now := r.Now()
	rec, ok := r.recs[id]
	if !ok {
		rec = &Record{ID: id, Session: session, CreatedAt: now}
		r.recs[id] = rec
	}
	rec.Kind = kind
	if repo != "" {
		rec.Repo = repo
	}
	if title != "" {
		rec.Title = title
	}
	rec.LastSeenAt = now
	r.save()
	return snapshot(rec)
}

// BindVoice assigns a persona to a record ONLY if it has none yet (sticky).
// Returns the effective voice name.
func (r *Registry) BindVoice(id, voice string) string {
	r.mu.Lock()
	defer r.mu.Unlock()
	rec, ok := r.recs[id]
	if !ok {
		return voice
	}
	if rec.Voice == "" {
		rec.Voice = voice
		r.save()
	}
	return rec.Voice
}

// Touch updates last_seen (and last_event when event=true).
func (r *Registry) Touch(id string, event bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	rec, ok := r.recs[id]
	if !ok {
		return
	}
	now := r.Now()
	rec.LastSeenAt = now
	if event {
		rec.LastEventAt = now
	}
	r.save()
}

// SetInput records (or clears, with empty kind) the agent's talk-back target.
func (r *Registry) SetInput(id, kind, target, socket string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if rec, ok := r.recs[id]; ok {
		rec.InputKind, rec.InputTarget, rec.InputSocket = kind, target, socket
		r.save()
	}
}

// SetTitle records the latest task headline as the agent's display title.
func (r *Registry) SetTitle(id, title string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if rec, ok := r.recs[id]; ok && title != "" {
		rec.Title = title
		r.save()
	}
}

// Evict removes a record entirely (management surface: DELETE /agents/{id}).
func (r *Registry) Evict(id string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.recs[id]; !ok {
		return false
	}
	delete(r.recs, id)
	r.save()
	return true
}

// Get returns a copy of one record.
func (r *Registry) Get(id string) (Record, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	rec, ok := r.recs[id]
	if !ok {
		return Record{}, false
	}
	return *snapshot(rec), true
}

// List returns copies of all records, most recently seen first.
func (r *Registry) List() []Record {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]Record, 0, len(r.recs))
	for _, rec := range r.recs {
		out = append(out, *snapshot(rec))
	}
	sort.Slice(out, func(i, j int) bool { return out[i].LastSeenAt.After(out[j].LastSeenAt) })
	return out
}

// VoicesInUse reports persona names currently bound to any record.
func (r *Registry) VoicesInUse() map[string]bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	used := map[string]bool{}
	for _, rec := range r.recs {
		if rec.Voice != "" {
			used[rec.Voice] = true
		}
	}
	return used
}

func snapshot(rec *Record) *Record {
	c := *rec
	return &c
}

// save persists under the held lock via tmp+rename (atomic on POSIX).
func (r *Registry) save() {
	if r.path == "" {
		return
	}
	recs := make([]*Record, 0, len(r.recs))
	for _, rec := range r.recs {
		recs = append(recs, rec)
	}
	sort.Slice(recs, func(i, j int) bool { return recs[i].CreatedAt.Before(recs[j].CreatedAt) })
	b, err := json.MarshalIndent(recs, "", "  ")
	if err != nil {
		return
	}
	tmp := r.path + ".tmp"
	if err := os.MkdirAll(filepath.Dir(r.path), 0o755); err != nil {
		return
	}
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return
	}
	_ = os.Rename(tmp, r.path)
}
