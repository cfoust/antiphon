// antiphond — the Antiphon agent bridge daemon. The wire protocol is documented in plugins/README.md.
//
//	antiphond serve    run the hub (default)
//	antiphond channel  per-session MCP subprocess for Claude Code (stdio ↔ hub)
//	antiphond emit     send one narration event from a hook/script (fail-open)
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"github.com/cfoust/antiphon/antiphond/internal/channel"
	"github.com/cfoust/antiphon/antiphond/internal/config"
	"github.com/cfoust/antiphon/antiphond/internal/emit"
	"github.com/cfoust/antiphon/antiphond/internal/hub"
	"github.com/cfoust/antiphon/antiphond/internal/registry"
	"github.com/cfoust/antiphon/antiphond/internal/tts"
	"github.com/cfoust/antiphon/antiphond/internal/voice"
)

// version is stamped by `just tag` (CalVer) and shipped in release builds.
var version = "0.0.0-dev"

func main() {
	args := os.Args[1:]
	if len(args) > 0 && (args[0] == "version" || args[0] == "-version" || args[0] == "--version") {
		fmt.Println("antiphond", version)
		return
	}
	mode := "serve"
	if len(args) > 0 && (args[0] == "serve" || args[0] == "channel" || args[0] == "emit") {
		mode = args[0]
		args = args[1:]
	}
	if mode == "emit" {
		os.Exit(emit.Run(args))
	}
	switch mode {
	case "channel":
		// stdout is the MCP transport — all logging must go to stderr
		log.SetOutput(os.Stderr)
		fs := flag.NewFlagSet("channel", flag.ExitOnError)
		hubURL := fs.String("hub", "", "hub /agent WebSocket URL (default $ANTIPHON_HUB or ws://127.0.0.1:8787/agent)")
		fs.Parse(args)
		if err := channel.New(*hubURL).Run(os.Stdin, os.Stdout); err != nil {
			log.Fatal(err)
		}
	case "serve":
		serve(args)
	}
}

func serve(args []string) {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	defaultPort := 8787
	if p, err := strconv.Atoi(os.Getenv("ANTIPHON_PORT")); err == nil {
		defaultPort = p
	}
	port := fs.Int("port", defaultPort, "listen port (127.0.0.1 only)")
	stateDir := fs.String("state", defaultStateDir(), "state directory (registry, tts cache, discovery file)")
	rosterPath := fs.String("roster", "", "optional roster JSON overriding the built-in personas")
	fs.Parse(args)

	if err := os.MkdirAll(*stateDir, 0o755); err != nil {
		log.Fatalf("state dir: %v", err)
	}

	// Log to a file too — the app spawns us with stdio discarded, and a silent
	// daemon is undebuggable. Truncated per run; this is a diagnostic, not history.
	if f, err := os.Create(filepath.Join(*stateDir, "antiphond.log")); err == nil {
		log.SetOutput(io.MultiWriter(os.Stderr, f))
	}

	reg, err := registry.Open(filepath.Join(*stateDir, "agents.json"))
	if err != nil {
		log.Fatalf("registry: %v", err)
	}

	roster := voice.Default()
	if *rosterPath != "" {
		if roster, err = voice.Load(*rosterPath); err != nil {
			log.Fatalf("roster: %v", err)
		}
	}

	// Provider ladder in priority order; macos-say is the free offline floor.
	// Built from ~/.antiphon/config.json (+ env-var key fallbacks) and rebuilt
	// live whenever the settings UI PUTs /config.
	cacheDir := filepath.Join(*stateDir, "tts-cache")
	buildTTS := func(cfg config.Config) hub.TTSSetup {
		providers := []tts.Provider{}
		if key := cfg.Key("elevenlabs", "ELEVENLABS_API_KEY"); key != "" && cfg.Provider("elevenlabs").On() {
			providers = append(providers, tts.NewElevenLabs(key))
		}
		if key := cfg.Key("openai", "OPENAI_API_KEY"); key != "" && cfg.Provider("openai").On() {
			providers = append(providers, tts.NewOpenAI(key))
		}
		if cfg.Provider("macos-say").On() {
			providers = append(providers, tts.Say{})
		}
		if len(providers) == 0 {
			log.Printf("all TTS providers disabled — narration will be silent")
		}
		return hub.TTSSetup{Chain: tts.NewChain(cacheDir, providers...), Providers: providers}
	}

	h := hub.New(reg, roster, buildTTS, filepath.Join(*stateDir, "config.json"))
	mux := http.NewServeMux()
	h.Routes(mux, cacheDir)

	addr := fmt.Sprintf("127.0.0.1:%d", *port)
	srv := &http.Server{Addr: addr, Handler: mux}

	// Discovery file: clients check this before touching the network, so
	// "antiphond isn't running" costs a stat(), not a connect timeout.
	discovery := filepath.Join(*stateDir, "antiphond.json")
	writeDiscovery(discovery, *port)
	defer os.Remove(discovery)

	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
		<-sig
		os.Remove(discovery)
		os.Exit(0)
	}()

	log.Printf("antiphond %s listening on %s (state: %s)", version, addr, *stateDir)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}

func defaultStateDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ".antiphon"
	}
	dir := filepath.Join(home, ".antiphon")
	// Migrate a pre-rename state dir (the daemon used to be chamberd).
	if _, err := os.Stat(dir); os.IsNotExist(err) {
		if old := filepath.Join(home, ".chamber"); dirExists(old) {
			if err := os.Rename(old, dir); err == nil {
				log.Printf("migrated state dir %s -> %s", old, dir)
			}
		}
	}
	return dir
}

func dirExists(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}

func writeDiscovery(path string, port int) {
	exe, _ := os.Executable() // lets the plugin launcher find THIS binary (e.g. inside Antiphon.app)
	b, _ := json.Marshal(map[string]any{
		"port":       port,
		"pid":        os.Getpid(),
		"exe":        exe,
		"started_at": time.Now().Format(time.RFC3339),
	})
	_ = os.WriteFile(path, b, 0o644)
}
