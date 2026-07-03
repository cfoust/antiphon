package input

import (
	"os"
	"testing"
)

// Manual injection check, used to verify binPath under a GUI-like PATH:
//
//	tmux -L chamtest new-session -d
//	go test -c -o /tmp/input.test ./internal/input
//	PATH=/usr/bin:/bin CHAMTEST_TMUX_SOCKET=<socket> CHAMTEST_TMUX_PANE=%0 \
//	  /tmp/input.test -test.run TestInjectTmuxManual -test.v
func TestInjectTmuxManual(t *testing.T) {
	socket, pane := os.Getenv("CHAMTEST_TMUX_SOCKET"), os.Getenv("CHAMTEST_TMUX_PANE")
	if socket == "" || pane == "" {
		t.Skip("set CHAMTEST_TMUX_SOCKET and CHAMTEST_TMUX_PANE to run")
	}
	info := Info{Kind: "tmux", Socket: socket, Target: pane}
	if err := info.Inject("hello from the restricted-PATH daemon"); err != nil {
		t.Fatalf("inject: %v", err)
	}
}

func TestBinPathFallsBack(t *testing.T) {
	// nonexistent tool: resolver must return the bare name so exec reports
	// its own clear error, not a panic or empty string
	if got := binPath("definitely-not-a-real-tool-xyz"); got != "definitely-not-a-real-tool-xyz" {
		t.Fatalf("binPath fallback = %q", got)
	}
}
