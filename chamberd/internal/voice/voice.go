// Package voice separates the two concepts the prototype fused: a PERSONA is
// the persistent identity an agent speaks with (name, color) and a REALIZATION
// is how a given TTS provider produces that persona. Provider failure swaps
// the realization, never the persona — that's the voice-consistency rule.
package voice

import (
	"encoding/json"
	"math"
	"os"
	"sort"
)

// Persona is one chamber voice. Realizations maps provider name → provider-
// specific voice id (ElevenLabs voice id, macOS `say` voice name, …). A
// missing entry means that provider can't speak this persona; an empty string
// means "provider default voice".
type Persona struct {
	Name         string            `json:"name"`
	Color        string            `json:"color"`
	Realizations map[string]string `json:"realizations"`
}

// Roster is the ordered set of personas; order doubles as seat order, matching
// the prototype's seat↔color↔voice binding so existing clients look right.
type Roster struct {
	Personas []Persona `json:"personas"`
}

// Default mirrors the prototype roster (web/bridge/roster.ts + generate.py):
// same ElevenLabs voice ids, plus macOS `say` realizations as the free floor.
func Default() Roster {
	p := func(name, color, eleven, say string) Persona {
		return Persona{Name: name, Color: color, Realizations: map[string]string{
			"elevenlabs": eleven,
			"macos-say":  say,
		}}
	}
	return Roster{Personas: []Persona{
		p("atlas", "#7aa2ff", "JBFqnCBsd6RMkjVDRZzb", "Daniel"),    // George, warm British
		p("echo", "#9aa6b8", "SAz9YHcvj6GT2YYXdXww", "Fred"),       // River, calm neutral
		p("wren", "#5fd0c5", "EXAVITQu4vr4xnSDxMaL", "Samantha"),   // Sarah, professional
		p("cass", "#ffce6b", "IKne3meq5aSn9XLyUdCD", "Junior"),     // Charlie, hyped
		p("iris", "#c08bff", "Xb7hH8MSUJpSbSDYk0k2", "Kathy"),      // Alice, clear British
		p("rook", "#ff9d7a", "bIHbv24MWmeRgasZH58o", "Ralph"),      // Will, relaxed
	}}
}

// Load reads a roster override from JSON — the "add a new voice" surface.
func Load(path string) (Roster, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return Roster{}, err
	}
	var r Roster
	if err := json.Unmarshal(b, &r); err != nil {
		return Roster{}, err
	}
	return r, nil
}

// Get looks a persona up by name.
func (r Roster) Get(name string) (Persona, bool) {
	for _, p := range r.Personas {
		if p.Name == name {
			return p, true
		}
	}
	return Persona{}, false
}

// Seat returns the seat index a persona owns (its roster position), or -1.
func (r Roster) Seat(name string) int {
	for i, p := range r.Personas {
		if p.Name == name {
			return i
		}
	}
	return -1
}

// Pick chooses a persona for a new agent: the first not in use — walking seats
// centre-out, so the first agents to arrive sit in front of the listener rather
// than at the edge of the arc — else the roster cycles (many agents, few
// voices — acceptable until seats grow).
func (r Roster) Pick(inUse map[string]bool) Persona {
	for _, i := range CenterOut(len(r.Personas)) {
		if p := r.Personas[i]; !inUse[p.Name] {
			return p
		}
	}
	// every voice is on stage: cycle, still centre-first
	order := CenterOut(len(r.Personas))
	return r.Personas[order[len(inUse)%len(r.Personas)]]
}

// CenterOut orders seat indices by distance from the middle of the arc:
// for 6 seats → [2 3 1 4 0 5]. Hosts place seat i at bearing
// -90° + 180°·i/(n-1), so "low distance from centre" = "in front".
func CenterOut(n int) []int {
	idx := make([]int, n)
	for i := range idx {
		idx[i] = i
	}
	mid := float64(n-1) / 2
	sort.SliceStable(idx, func(a, b int) bool {
		da, db := math.Abs(float64(idx[a])-mid), math.Abs(float64(idx[b])-mid)
		if da != db {
			return da < db
		}
		return idx[a] < idx[b]
	})
	return idx
}
