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

// OpenAI is the OpenAI speech API (POST /v1/audio/speech). One model tier —
// gpt-4o-mini-tts is already low-latency — so the flash/quality split is moot.
// (Whisper is their speech-to-TEXT model; this is the text-to-speech side.)
type OpenAI struct {
	APIKey string
	Client *http.Client
}

func NewOpenAI(apiKey string) *OpenAI {
	return &OpenAI{APIKey: apiKey, Client: &http.Client{Timeout: 30 * time.Second}}
}

func (o *OpenAI) Name() string { return "openai" }

func (o *OpenAI) Synthesize(ctx context.Context, voiceID, text string, _ bool) ([]byte, string, error) {
	if o.APIKey == "" {
		return nil, "", errors.New("openai: no api key")
	}
	if voiceID == "" {
		voiceID = "alloy"
	}
	body, _ := json.Marshal(map[string]any{
		"model":           "gpt-4o-mini-tts",
		"voice":           voiceID,
		"input":           text,
		"response_format": "mp3",
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		"https://api.openai.com/v1/audio/speech", bytes.NewReader(body))
	if err != nil {
		return nil, "", err
	}
	req.Header.Set("authorization", "Bearer "+o.APIKey)
	req.Header.Set("content-type", "application/json")

	resp, err := o.Client.Do(req)
	if err != nil {
		return nil, "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return nil, "", fmt.Errorf("openai: %s: %s", resp.Status, string(msg))
	}
	audio, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, "", err
	}
	return audio, "mp3", nil
}

// Voices is the published set for the speech API — there is no listing
// endpoint, so this is the one provider with a static list.
func (o *OpenAI) Voices(context.Context) ([]Voice, error) {
	names := []string{"alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer"}
	voices := make([]Voice, len(names))
	for i, n := range names {
		voices[i] = Voice{ID: n, Name: n}
	}
	return voices, nil
}
