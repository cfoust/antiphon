package registry

import (
	"path/filepath"
	"testing"
	"time"
)

func TestReclaimBySessionKeepsIdentityAndVoice(t *testing.T) {
	r, _ := Open("")
	a := r.Upsert("session-1", "claude-code", "cfoust/antiphon", "fix bug", "/tmp/antiphon", "main")
	r.BindVoice(a.ID, "wren")

	b := r.Upsert("session-1", "claude-code", "", "", "", "")
	if b.ID != a.ID {
		t.Fatalf("reclaim changed id: %s -> %s", a.ID, b.ID)
	}
	got, _ := r.Get(b.ID)
	if got.Voice != "wren" {
		t.Fatalf("voice not sticky across reclaim: %q", got.Voice)
	}
	if got.Repo != "cfoust/antiphon" {
		t.Fatalf("empty repo on reclaim clobbered stored repo: %q", got.Repo)
	}
	if !got.CreatedAt.Equal(a.CreatedAt) {
		t.Fatal("created_at changed on reclaim")
	}
}

func TestBindVoiceIsSticky(t *testing.T) {
	r, _ := Open("")
	a := r.Upsert("s", "debug", "", "", "", "")
	if v := r.BindVoice(a.ID, "atlas"); v != "atlas" {
		t.Fatalf("first bind: %q", v)
	}
	if v := r.BindVoice(a.ID, "rook"); v != "atlas" {
		t.Fatalf("rebind must not change persona: %q", v)
	}
}

func TestTouchSeparatesSeenFromEvent(t *testing.T) {
	r, _ := Open("")
	now := time.Date(2026, 7, 2, 12, 0, 0, 0, time.UTC)
	r.Now = func() time.Time { return now }
	a := r.Upsert("s", "debug", "", "", "", "")

	now = now.Add(time.Minute)
	r.Touch(a.ID, false) // heartbeat, not an event
	got, _ := r.Get(a.ID)
	if !got.LastSeenAt.Equal(now) {
		t.Fatal("last_seen not updated")
	}
	if got.LastEventAt.Equal(now) {
		t.Fatal("heartbeat must not count as an event")
	}

	now = now.Add(time.Minute)
	r.Touch(a.ID, true)
	got, _ = r.Get(a.ID)
	if !got.LastEventAt.Equal(now) {
		t.Fatal("event not recorded")
	}
}

func TestPersistenceRoundtrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agents.json")
	r, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	a := r.Upsert("session-x", "claude-code", "repo", "title", "", "")
	r.BindVoice(a.ID, "iris")

	r2, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	got, ok := r2.Get(a.ID)
	if !ok {
		t.Fatal("record lost across restart")
	}
	if got.Voice != "iris" || got.Session != "session-x" {
		t.Fatalf("bad roundtrip: %+v", got)
	}
}

func TestEvict(t *testing.T) {
	r, _ := Open("")
	a := r.Upsert("s", "debug", "", "", "", "")
	if !r.Evict(a.ID) {
		t.Fatal("evict reported failure")
	}
	if _, ok := r.Get(a.ID); ok {
		t.Fatal("record survived evict")
	}
	if r.Evict(a.ID) {
		t.Fatal("double evict reported success")
	}
}
