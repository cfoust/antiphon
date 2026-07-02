// chamberd — the Chamber agent bridge daemon. See docs/agent-bridge.md.
//
//	chamberd serve    run the hub (default)
//	chamberd channel  per-session MCP subprocess for Claude Code (stdio ↔ hub)
//	chamberd emit     send one narration event from a hook/script (fail-open)
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"github.com/cfoust/chamber/chamberd/internal/channel"
	"github.com/cfoust/chamber/chamberd/internal/emit"
	"github.com/cfoust/chamber/chamberd/internal/hub"
	"github.com/cfoust/chamber/chamberd/internal/registry"
	"github.com/cfoust/chamber/chamberd/internal/tts"
	"github.com/cfoust/chamber/chamberd/internal/voice"
)

func main() {
	args := os.Args[1:]
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
		hubURL := fs.String("hub", "", "hub /agent WebSocket URL (default $CHAMBER_HUB or ws://127.0.0.1:8787/agent)")
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
	if p, err := strconv.Atoi(os.Getenv("CHAMBER_PORT")); err == nil {
		defaultPort = p
	}
	port := fs.Int("port", defaultPort, "listen port (127.0.0.1 only)")
	stateDir := fs.String("state", defaultStateDir(), "state directory (registry, tts cache, discovery file)")
	rosterPath := fs.String("roster", "", "optional roster JSON overriding the built-in personas")
	fs.Parse(args)

	if err := os.MkdirAll(*stateDir, 0o755); err != nil {
		log.Fatalf("state dir: %v", err)
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
	cacheDir := filepath.Join(*stateDir, "tts-cache")
	providers := []tts.Provider{}
	if key := os.Getenv("ELEVENLABS_API_KEY"); key != "" {
		providers = append(providers, tts.NewElevenLabs(key))
	} else {
		log.Printf("ELEVENLABS_API_KEY not set — using macOS say only")
	}
	providers = append(providers, tts.Say{})
	chain := tts.NewChain(cacheDir, providers...)

	h := hub.New(reg, roster, chain)
	mux := http.NewServeMux()
	h.Routes(mux, cacheDir)

	addr := fmt.Sprintf("127.0.0.1:%d", *port)
	srv := &http.Server{Addr: addr, Handler: mux}

	// Discovery file: clients check this before touching the network, so
	// "chamberd isn't running" costs a stat(), not a connect timeout.
	discovery := filepath.Join(*stateDir, "chamberd.json")
	writeDiscovery(discovery, *port)
	defer os.Remove(discovery)

	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
		<-sig
		os.Remove(discovery)
		os.Exit(0)
	}()

	log.Printf("chamberd listening on %s (state: %s)", addr, *stateDir)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}

func defaultStateDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ".chamber"
	}
	return filepath.Join(home, ".chamber")
}

func writeDiscovery(path string, port int) {
	exe, _ := os.Executable() // lets the plugin launcher find THIS binary (e.g. inside Chamber.app)
	b, _ := json.Marshal(map[string]any{
		"port":       port,
		"pid":        os.Getpid(),
		"exe":        exe,
		"started_at": time.Now().Format(time.RFC3339),
	})
	_ = os.WriteFile(path, b, 0o644)
}
