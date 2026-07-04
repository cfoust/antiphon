// Package config is antiphond's persisted settings: ~/.antiphon/config.json,
// written by the app's Settings UI (PUT /config) and read at startup and on
// every change. Environment variables (ELEVENLABS_API_KEY, OPENAI_API_KEY)
// remain as fallbacks so existing setups keep working without a file.
package config

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// Provider is one TTS provider's settings. Enabled is a pointer so a PUT can
// distinguish "not mentioned" (keep) from an explicit true/false.
type Provider struct {
	Enabled *bool  `json:"enabled,omitempty"`
	APIKey  string `json:"api_key,omitempty"`
	// Per-voice overrides (voice id → on/off). A voice with no entry follows
	// the provider's default policy (see hub.defaultVoiceOn) — which is how
	// macOS's less-interpretable voices start off without hiding them.
	Voices map[string]bool `json:"voices,omitempty"`
}

// On reports whether the provider is enabled (default: yes).
func (p Provider) On() bool { return p.Enabled == nil || *p.Enabled }

type Config struct {
	Providers map[string]Provider `json:"providers,omitempty"`
}

// Provider returns the (possibly zero) settings for a provider name.
func (c Config) Provider(name string) Provider { return c.Providers[name] }

// Key resolves a provider's API key: the config file wins, else the env var.
func (c Config) Key(provider, envVar string) string {
	if k := c.Providers[provider].APIKey; k != "" {
		return k
	}
	return os.Getenv(envVar)
}

// Load reads the config file; a missing file is a valid empty config.
func Load(path string) Config {
	var c Config
	b, err := os.ReadFile(path)
	if err == nil {
		_ = json.Unmarshal(b, &c)
	}
	if c.Providers == nil {
		c.Providers = map[string]Provider{}
	}
	return c
}

// Save writes the config atomically (tmp + rename), 0600 — it holds API keys.
func (c Config) Save(path string) error {
	b, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	tmp := filepath.Join(filepath.Dir(path), ".config.json.tmp")
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
