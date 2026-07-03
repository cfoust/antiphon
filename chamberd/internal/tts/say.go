package tts

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

// Say is the macOS built-in TTS — the free, offline floor of the ladder.
// Renders WAVE/LEI16 at 48 kHz, natively matched to the engine's pinned rate.
type Say struct{}

func (Say) Name() string { return "macos-say" }

func (Say) Synthesize(ctx context.Context, voiceID, text string, _ bool) ([]byte, string, error) {
	tmp, err := os.CreateTemp("", "chamber-say-*.wav")
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
