package tts

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"
)

// ElevenLabs matches the prototype bridge exactly (web/bridge/tts.ts): same
// endpoint, same model split (flash for low-latency progress lines, quality
// for identity/summary), same voice settings, mp3_44100_128 output.
type ElevenLabs struct {
	APIKey string
	Client *http.Client
}

const (
	elevenFlash   = "eleven_flash_v2_5"
	elevenQuality = "eleven_multilingual_v2"
)

func NewElevenLabs(apiKey string) *ElevenLabs {
	return &ElevenLabs{APIKey: apiKey, Client: &http.Client{Timeout: 30 * time.Second}}
}

func (e *ElevenLabs) Name() string { return "elevenlabs" }

func (e *ElevenLabs) Synthesize(ctx context.Context, voiceID, text string, lowLatency bool) ([]byte, string, error) {
	if e.APIKey == "" {
		return nil, "", errors.New("elevenlabs: no api key")
	}
	model := elevenQuality
	if lowLatency {
		model = elevenFlash
	}
	body, _ := json.Marshal(map[string]any{
		"text":     text,
		"model_id": model,
		"voice_settings": map[string]any{
			"stability":        0.5,
			"similarity_boost": 0.75,
		},
	})
	url := fmt.Sprintf("https://api.elevenlabs.io/v1/text-to-speech/%s?output_format=mp3_44100_128", voiceID)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, "", err
	}
	req.Header.Set("xi-api-key", e.APIKey)
	req.Header.Set("content-type", "application/json")

	resp, err := e.Client.Do(req)
	if err != nil {
		return nil, "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return nil, "", fmt.Errorf("elevenlabs: %s: %s", resp.Status, string(msg))
	}
	audio, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, "", err
	}
	return audio, "mp3", nil
}

// Voices lists the account's voice library (GET /v1/voices).
func (e *ElevenLabs) Voices(ctx context.Context) ([]Voice, error) {
	if e.APIKey == "" {
		return nil, errors.New("elevenlabs: no api key")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://api.elevenlabs.io/v1/voices", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("xi-api-key", e.APIKey)
	resp, err := e.Client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return nil, fmt.Errorf("elevenlabs voices: %s: %s", resp.Status, string(msg))
	}
	var out struct {
		Voices []struct {
			VoiceID string `json:"voice_id"`
			Name    string `json:"name"`
		} `json:"voices"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	voices := make([]Voice, 0, len(out.Voices))
	for _, v := range out.Voices {
		voices = append(voices, Voice{ID: v.VoiceID, Name: v.Name})
	}
	return voices, nil
}
