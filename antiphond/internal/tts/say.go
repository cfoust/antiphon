package tts

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// Say is the macOS built-in TTS — the free, offline floor of the ladder.
// Renders WAVE/LEI16 at 48 kHz, natively matched to the engine's pinned rate.
type Say struct{}

func (Say) Name() string { return "macos-say" }

func (Say) Synthesize(ctx context.Context, voiceID, text string, _ bool) ([]byte, string, error) {
	tmp, err := os.CreateTemp("", "antiphon-say-*.wav")
	if err != nil {
		return nil, "", err
	}
	tmpPath := tmp.Name()
	tmp.Close()
	defer os.Remove(tmpPath)

	args := []string{
		"-o", tmpPath,
		"--file-format=WAVE",
		"--data-format=LEI16@48000",
	}
	if voiceID != "" { // empty realization = system default voice
		args = append(args, "-v", voiceID)
	}
	args = append(args, text)

	cmd := exec.CommandContext(ctx, "say", args...)
	if out, err := cmd.CombinedOutput(); err != nil {
		return nil, "", fmt.Errorf("say: %w (%s)", err, string(out))
	}
	b, err := os.ReadFile(filepath.Clean(tmpPath))
	if err != nil {
		return nil, "", err
	}
	return b, "wav", nil
}

// sayVoiceLine parses one `say -v ?` row: "Name  loc_ALE  # sample sentence".
// Voice names may contain spaces ("Bad News"), so anchor on the locale column.
var sayVoiceLine = regexp.MustCompile(`^(.+?)\s+([a-z]{2,3}[_-][A-Za-z0-9_-]+)\s+#`)

// The classic macOS novelty/effect voices. Agents get voices assigned at
// RANDOM from the pool — nobody wants their build narrated by Bells.
var sayNovelty = map[string]bool{
	"Albert": true, "Bad News": true, "Bahh": true, "Bells": true,
	"Boing": true, "Bubbles": true, "Cellos": true, "Deranged": true,
	"Fred": true, "Good News": true, "Hysterical": true, "Jester": true,
	"Junior": true, "Kathy": true, "Organ": true, "Pipe Organ": true,
	"Princess": true, "Ralph": true, "Superstar": true, "Trinoids": true,
	"Whisper": true, "Wobble": true, "Zarvox": true,
}

// Voices lists the installed English `say` voices at runtime (novelty voices
// excluded).
func (Say) Voices(ctx context.Context) ([]Voice, error) {
	out, err := exec.CommandContext(ctx, "say", "-v", "?").Output()
	if err != nil {
		return nil, fmt.Errorf("say -v ?: %w", err)
	}
	var voices []Voice
	for _, line := range strings.Split(string(out), "\n") {
		m := sayVoiceLine.FindStringSubmatch(line)
		if m == nil || !strings.HasPrefix(m[2], "en") {
			continue
		}
		name := strings.TrimSpace(m[1])
		if sayNovelty[name] {
			continue
		}
		voices = append(voices, Voice{ID: name, Name: name})
	}
	return voices, nil
}
