package hub

import (
	"context"
	"encoding/json"
	"log"
	"math/rand"
	"net/http"
	"strings"
	"time"

	"github.com/cfoust/chamber/chamberd/internal/config"
	"github.com/cfoust/chamber/chamberd/internal/tts"
)

// The settings surface: GET/PUT /config (provider enable + API keys, persisted
// to ~/.chamber/config.json) and GET /voices (the runtime-discovered voice
// pool). New agents draw a random voice from the pool across every enabled
// provider; the pick is sticky per session (registry.BindTTS).

// TTSSetup is what the daemon builds from a Config: the synthesis ladder plus
// the provider list the hub discovers voices from. Rebuilt on every PUT /config.
type TTSSetup struct {
	Chain     *tts.Chain
	Providers []tts.Provider
}

// VoiceRef is one entry of the cross-provider voice pool. Enabled reflects the
// user's per-voice toggle (or the provider's default policy); only enabled
// voices are assigned to agents, but the UI sees the whole list.
type VoiceRef struct {
	Provider string `json:"provider"`
	ID       string `json:"id"`
	Name     string `json:"name"`
	Enabled  bool   `json:"enabled"`
}

// sayDefaultOn is the curated set of macOS voices that read clearly enough to
// narrate work. Everything else `say` ships defaults OFF (togglable in the
// settings UI) — several of the stock voices are basically uninterpretable.
var sayDefaultOn = map[string]bool{
	"Alex": true, "Daniel": true, "Fiona": true, "Karen": true, "Moira": true,
	"Rishi": true, "Samantha": true, "Tessa": true, "Veena": true,
}

// defaultVoiceOn is the policy for voices with no explicit config override.
func defaultVoiceOn(provider, id string) bool {
	if provider != "macos-say" {
		return true
	}
	// locale-decorated names ("Samantha (English (US))") match on the base name
	base := id
	if i := strings.IndexByte(base, '('); i > 0 {
		base = strings.TrimSpace(base[:i])
	}
	return sayDefaultOn[base]
}

// voiceEnabled resolves a voice's on/off state: explicit override, else policy.
func (h *Hub) voiceEnabled(cfg config.Config, provider, id string) bool {
	if on, ok := cfg.Provider(provider).Voices[id]; ok {
		return on
	}
	return defaultVoiceOn(provider, id)
}

const voicePoolTTL = 10 * time.Minute

// envKeyVar maps provider name → API-key env var (the pre-config fallback).
var envKeyVar = map[string]string{
	"elevenlabs": "ELEVENLABS_API_KEY",
	"openai":     "OPENAI_API_KEY",
}

// knownProviders is the fixed set the settings UI shows, in ladder order.
var knownProviders = []string{"elevenlabs", "openai", "macos-say"}

// refreshVoices re-discovers the pool from the current providers (called in a
// goroutine at startup, after config changes, and when the cache goes stale).
func (h *Hub) refreshVoices() {
	h.mu.Lock()
	providers := make([]tts.Provider, len(h.providers))
	copy(providers, h.providers)
	cfg := h.cfg
	h.mu.Unlock()

	pool := []VoiceRef{}
	errs := map[string]string{}
	for _, p := range providers {
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		voices, err := p.Voices(ctx)
		cancel()
		if err != nil {
			errs[p.Name()] = err.Error()
			log.Printf("voices: %s discovery failed: %v", p.Name(), err)
			continue
		}
		for _, v := range voices {
			pool = append(pool, VoiceRef{
				Provider: p.Name(), ID: v.ID, Name: v.Name,
				Enabled: h.voiceEnabled(cfg, p.Name(), v.ID),
			})
		}
	}
	h.voiceMu.Lock()
	h.pool, h.poolErrs, h.poolAt = pool, errs, time.Now()
	h.voiceMu.Unlock()
	on := 0
	for _, v := range pool {
		if v.Enabled {
			on++
		}
	}
	log.Printf("voices: pool has %d voices (%d enabled) across %d providers", len(pool), on, len(providers))
}

// voicePool returns the cached pool, kicking an async refresh when stale.
func (h *Hub) voicePool() []VoiceRef {
	h.voiceMu.Lock()
	stale := time.Since(h.poolAt) > voicePoolTTL
	pool := h.pool
	h.voiceMu.Unlock()
	if stale {
		go h.refreshVoices()
	}
	return pool
}

// assignTTS gives a record its sticky spoken voice: a random draw from the
// ENABLED voices of the cross-provider pool. No pool yet (offline, discovery
// pending) or everything toggled off = no assignment; the persona's built-in
// realizations keep working and the next bind retries.
func (h *Hub) assignTTS(id string) {
	rec, ok := h.reg.Get(id)
	if !ok || rec.TTSProvider != "" {
		return
	}
	on := []VoiceRef{}
	for _, v := range h.voicePool() {
		if v.Enabled {
			on = append(on, v)
		}
	}
	if len(on) == 0 {
		return
	}
	v := on[rand.Intn(len(on))]
	h.reg.BindTTS(id, v.Provider, v.ID, v.Name)
	log.Printf("agent %s speaks with %s/%s", id, v.Provider, v.Name)
}

// handleConfig is the settings endpoint: GET returns provider status (keys
// reported as set/unset, never echoed); PUT merges partial updates, persists,
// and rebuilds the TTS ladder live.
func (h *Hub) handleConfig(w http.ResponseWriter, r *http.Request) {
	cors(w)
	switch r.Method {
	case http.MethodOptions:
		return
	case http.MethodGet:
		h.writeConfigView(w)
	case http.MethodPut, http.MethodPost:
		var in struct {
			Providers map[string]struct {
				Enabled *bool           `json:"enabled"`
				APIKey  *string         `json:"api_key"`
				Voices  map[string]bool `json:"voices"` // per-voice toggles, merged
			} `json:"providers"`
		}
		if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
			http.Error(w, "bad config", http.StatusBadRequest)
			return
		}
		h.mu.Lock()
		for name, p := range in.Providers {
			cur := h.cfg.Providers[name]
			if p.Enabled != nil {
				cur.Enabled = p.Enabled
			}
			if p.APIKey != nil { // explicit "" clears a stored key
				cur.APIKey = *p.APIKey
			}
			for id, on := range p.Voices {
				if cur.Voices == nil {
					cur.Voices = map[string]bool{}
				}
				cur.Voices[id] = on
			}
			h.cfg.Providers[name] = cur
		}
		cfg := h.cfg
		if err := cfg.Save(h.cfgPath); err != nil {
			h.mu.Unlock()
			log.Printf("config: save failed: %v", err)
			http.Error(w, "save failed", http.StatusInternalServerError)
			return
		}
		setup := h.buildTTS(cfg)
		h.chain, h.providers = setup.Chain, setup.Providers
		h.mu.Unlock()
		log.Printf("config updated — TTS ladder rebuilt (%d providers)", len(setup.Providers))
		// re-stamp the cached pool's enabled flags NOW (a voice toggle must not
		// wait on a slow rediscovery), then rediscover in the background
		h.voiceMu.Lock()
		for i := range h.pool {
			h.pool[i].Enabled = h.voiceEnabled(cfg, h.pool[i].Provider, h.pool[i].ID)
		}
		h.voiceMu.Unlock()
		go h.refreshVoices()
		h.writeConfigView(w)
	default:
		http.Error(w, "GET or PUT", http.StatusMethodNotAllowed)
	}
}

func (h *Hub) writeConfigView(w http.ResponseWriter) {
	h.mu.Lock()
	cfg := h.cfg
	active := map[string]bool{}
	for _, p := range h.providers {
		active[p.Name()] = true
	}
	h.mu.Unlock()
	type view struct {
		Enabled  bool `json:"enabled"`
		NeedsKey bool `json:"needs_key"`
		KeySet   bool `json:"key_set"`
		Active   bool `json:"active"` // actually in the ladder right now
	}
	out := map[string]view{}
	for _, name := range knownProviders {
		env := envKeyVar[name]
		out[name] = view{
			Enabled:  cfg.Provider(name).On(),
			NeedsKey: env != "",
			KeySet:   env == "" || cfg.Key(name, env) != "",
			Active:   active[name],
		}
	}
	w.Header().Set("content-type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"providers": out})
}

// handleVoices reports the discovered pool. ?refresh=1 re-discovers first
// (the settings UI's refresh button; provider APIs can take a few seconds).
func (h *Hub) handleVoices(w http.ResponseWriter, r *http.Request) {
	cors(w)
	if r.Method == http.MethodOptions {
		return
	}
	if r.URL.Query().Get("refresh") != "" {
		h.refreshVoices()
	} else {
		h.voicePool() // kicks an async refresh when stale
	}
	h.voiceMu.Lock()
	pool := h.pool
	errs := h.poolErrs
	at := h.poolAt
	h.voiceMu.Unlock()
	w.Header().Set("content-type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"voices":       pool,
		"errors":       errs,
		"refreshed_at": at.Format(time.RFC3339),
	})
}
