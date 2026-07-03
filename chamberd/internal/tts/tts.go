// Package tts renders narration text to audio through an ordered provider
// chain with the failure semantics the design doc pins down:
//
//	priority order → circuit breaker per provider → content-addressed cache
//	→ degraded flag when a fallback spoke.
//
// The breaker is what makes fallback INSTANT once a provider is down (e.g.
// ElevenLabs credits exhausted): after a few consecutive failures the dead
// provider is skipped without a network round-trip, then re-probed later.
// The chain never errors the caller for provider trouble: worst case it
// returns ErrSilent and the frame ships without audio (prototype behavior
// when no API key was set).
package tts

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/cfoust/chamber/chamberd/internal/voice"
)

// Provider is one TTS engine.
type Provider interface {
	Name() string
	// Synthesize renders text with the provider-specific voice id and returns
	// (audio bytes, file extension without dot).
	Synthesize(ctx context.Context, voiceID, text string, lowLatency bool) ([]byte, string, error)
	// Voices lists the provider's available voices, discovered at runtime
	// where the provider supports it (API listing, `say -v ?` parsing) and
	// static where it doesn't. Agents are assigned a random voice from the
	// union of every enabled provider's list.
	Voices(ctx context.Context) ([]Voice, error)
}

// Voice is one selectable voice of a provider.
type Voice struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// ErrSilent means every provider was unavailable; ship the frame without audio.
var ErrSilent = errors.New("tts: no provider available")

// Result is one rendered line.
type Result struct {
	Path     string // file in the cache dir
	Ext      string // "wav" | "mp3"
	Provider string
	Degraded bool // a lower-priority provider than the persona's best spoke
	Cached   bool
}

const (
	breakerThreshold = 3                // consecutive failures to open
	breakerCooldown  = 60 * time.Second // open duration before a half-open probe
)

type breaker struct {
	fails    int
	openedAt time.Time
	probing  bool
}

func (b *breaker) available(now time.Time) bool {
	if b.fails < breakerThreshold {
		return true
	}
	if now.Sub(b.openedAt) >= breakerCooldown && !b.probing {
		b.probing = true // half-open: let exactly one request through
		return true
	}
	return false
}

func (b *breaker) record(ok bool, now time.Time) {
	b.probing = false
	if ok {
		b.fails = 0
		return
	}
	b.fails++
	if b.fails == breakerThreshold {
		b.openedAt = now
	} else if b.fails > breakerThreshold {
		b.openedAt = now // failed probe re-opens the window
	}
}

// Chain is the provider ladder.
type Chain struct {
	mu        sync.Mutex
	providers []Provider
	breakers  map[string]*breaker
	cacheDir  string
	Now       func() time.Time
}

// NewChain builds a ladder in priority order.
func NewChain(cacheDir string, providers ...Provider) *Chain {
	c := &Chain{
		providers: providers,
		breakers:  map[string]*breaker{},
		cacheDir:  cacheDir,
		Now:       time.Now,
	}
	for _, p := range providers {
		c.breakers[p.Name()] = &breaker{}
	}
	return c
}

// Speak renders text in a persona's voice, walking the ladder. Degraded is
// true when a provider below the persona's best-available realization spoke.
func (c *Chain) Speak(ctx context.Context, p voice.Persona, text string, lowLatency bool) (*Result, error) {
	if text == "" {
		return nil, ErrSilent
	}
	best := -1 // index of the first provider that HAS a realization for p
	for i, prov := range c.providers {
		voiceID, ok := p.Realizations[prov.Name()]
		if !ok {
			continue
		}
		if best < 0 {
			best = i
		}

		// cache first — a hit costs nothing and doesn't touch breaker/budget
		key := cacheKey(prov.Name(), voiceID, text)
		if res, ok := c.cacheHit(key); ok {
			res.Provider = prov.Name()
			res.Degraded = i > best
			return res, nil
		}

		c.mu.Lock()
		br := c.breakers[prov.Name()]
		usable := br.available(c.Now())
		c.mu.Unlock()
		if !usable {
			continue
		}

		audio, ext, err := prov.Synthesize(ctx, voiceID, text, lowLatency)
		c.mu.Lock()
		br.record(err == nil, c.Now())
		c.mu.Unlock()
		if err != nil {
			log.Printf("tts: %s failed (%v), falling through", prov.Name(), err)
			continue
		}

		path, werr := c.cachePut(key, ext, audio)
		if werr != nil {
			return nil, werr
		}
		return &Result{Path: path, Ext: ext, Provider: prov.Name(), Degraded: i > best}, nil
	}
	return nil, ErrSilent
}

func cacheKey(provider, voiceID, text string) string {
	h := sha256.Sum256([]byte(provider + "\x00" + voiceID + "\x00" + text))
	return hex.EncodeToString(h[:])
}

func (c *Chain) cacheHit(key string) (*Result, bool) {
	for _, ext := range []string{"wav", "mp3"} {
		p := filepath.Join(c.cacheDir, key+"."+ext)
		if _, err := os.Stat(p); err == nil {
			return &Result{Path: p, Ext: ext, Cached: true}, true
		}
	}
	return nil, false
}

func (c *Chain) cachePut(key, ext string, audio []byte) (string, error) {
	if err := os.MkdirAll(c.cacheDir, 0o755); err != nil {
		return "", err
	}
	p := filepath.Join(c.cacheDir, key+"."+ext)
	tmp := fmt.Sprintf("%s.tmp-%d", p, os.Getpid())
	if err := os.WriteFile(tmp, audio, 0o644); err != nil {
		return "", err
	}
	return p, os.Rename(tmp, p)
}
