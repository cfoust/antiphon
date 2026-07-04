package tts

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/cfoust/antiphon/antiphond/internal/voice"
)

type fake struct {
	name  string
	fail  bool
	calls int
}

func (f *fake) Name() string { return f.name }
func (f *fake) Synthesize(_ context.Context, _, text string, _ bool) ([]byte, string, error) {
	f.calls++
	if f.fail {
		return nil, "", errors.New("boom")
	}
	return []byte("audio:" + text), "wav", nil
}
func (f *fake) Voices(context.Context) ([]Voice, error) {
	return []Voice{{ID: "voice-id", Name: f.name + " voice"}}, nil
}

func persona(providers ...string) voice.Persona {
	r := map[string]string{}
	for _, p := range providers {
		r[p] = "voice-id"
	}
	return voice.Persona{Name: "wren", Realizations: r}
}

func TestFallsThroughToNextProviderAndFlagsDegraded(t *testing.T) {
	primary := &fake{name: "elevenlabs", fail: true}
	floor := &fake{name: "macos-say"}
	c := NewChain(t.TempDir(), primary, floor)

	res, err := c.Speak(context.Background(), persona("elevenlabs", "macos-say"), "hello", false)
	if err != nil {
		t.Fatal(err)
	}
	if res.Provider != "macos-say" || !res.Degraded {
		t.Fatalf("want degraded macos-say, got %+v", res)
	}
}

func TestBreakerOpensAfterConsecutiveFailuresAndProbes(t *testing.T) {
	primary := &fake{name: "elevenlabs", fail: true}
	floor := &fake{name: "macos-say"}
	c := NewChain(t.TempDir(), primary, floor)
	now := time.Date(2026, 7, 2, 12, 0, 0, 0, time.UTC)
	c.Now = func() time.Time { return now }

	for i := 0; i < breakerThreshold; i++ {
		// unique text so the cache never short-circuits the ladder
		if _, err := c.Speak(context.Background(), persona("elevenlabs", "macos-say"), "line"+string(rune('a'+i)), false); err != nil {
			t.Fatal(err)
		}
	}
	if primary.calls != breakerThreshold {
		t.Fatalf("expected %d tries before opening, got %d", breakerThreshold, primary.calls)
	}

	// breaker open: primary must be skipped without a call
	if _, err := c.Speak(context.Background(), persona("elevenlabs", "macos-say"), "while-open", false); err != nil {
		t.Fatal(err)
	}
	if primary.calls != breakerThreshold {
		t.Fatalf("open breaker still called primary (%d calls)", primary.calls)
	}

	// after cooldown: exactly one half-open probe; success closes the breaker
	now = now.Add(breakerCooldown + time.Second)
	primary.fail = false
	res, err := c.Speak(context.Background(), persona("elevenlabs", "macos-say"), "probe", false)
	if err != nil {
		t.Fatal(err)
	}
	if res.Provider != "elevenlabs" || res.Degraded {
		t.Fatalf("recovered provider should speak undegraded: %+v", res)
	}
}

func TestCacheHitSkipsProvider(t *testing.T) {
	p := &fake{name: "macos-say"}
	c := NewChain(t.TempDir(), p)
	pa := persona("macos-say")

	if _, err := c.Speak(context.Background(), pa, "same line", false); err != nil {
		t.Fatal(err)
	}
	res, err := c.Speak(context.Background(), pa, "same line", false)
	if err != nil {
		t.Fatal(err)
	}
	if !res.Cached || p.calls != 1 {
		t.Fatalf("second render should be a cache hit (calls=%d, %+v)", p.calls, res)
	}
}

func TestNoRealizationNoProviderMeansSilent(t *testing.T) {
	c := NewChain(t.TempDir(), &fake{name: "elevenlabs", fail: true})
	// persona only realized on a provider that keeps failing
	if _, err := c.Speak(context.Background(), persona("elevenlabs"), "x", false); !errors.Is(err, ErrSilent) {
		// first failure falls off the ladder end → silent
		t.Fatalf("want ErrSilent, got %v", err)
	}
	// persona with no realization at all
	if _, err := c.Speak(context.Background(), voice.Persona{Name: "ghost"}, "x", false); !errors.Is(err, ErrSilent) {
		t.Fatalf("want ErrSilent, got %v", err)
	}
}
