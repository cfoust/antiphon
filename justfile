# Chamber top-level recipes. (Web recipes live in web/justfile.)

# Generate ambient "agent waiting" sound-design concepts -> out/concepts/*.wav
concepts:
    uv run tools/sound_concepts.py

# List generated concepts
concepts-list:
    @cat out/concepts/INDEX.md 2>/dev/null || echo "run `just concepts` first"

# Render one mono clip statically close to one ear, through the engine (near-field + reverb).
# usage: just nearfield in.wav out.wav [R|L] [dist] [gain] [room] [send]
nearfield IN OUT SIDE="R" DIST="0.12" GAIN="0.10" ROOM="room" SEND="0.30":
    cargo run -q -p chamber-render --release -- nearfield {{IN}} {{OUT}} {{SIDE}} {{DIST}} {{GAIN}} {{ROOM}} {{SEND}}

# Regenerate all near-ear engine renders (drone-stripped + pulse sources, through reverb, quiet).
ear-concepts: concepts
    #!/usr/bin/env bash
    set -euo pipefail
    cargo build -q -p chamber-render --release
    BIN=target/release/chamber-render
    mkdir -p out/concepts/engine
    nf() { $BIN nearfield "$@"; }
    # held-chord originals, now with reverb, quieter (0.06 whisper / 0.10 soft)
    nf out/concepts/src/A3_accretion_src.wav out/concepts/engine/A3_accretion_earR_whisper.wav R 0.12 0.06
    nf out/concepts/src/A3_accretion_src.wav out/concepts/engine/A3_accretion_earR_soft.wav    R 0.12 0.10
    nf out/concepts/src/A2_rhodes_src.wav    out/concepts/engine/A2_rhodes_earR_soft.wav       R 0.12 0.10
    # recurring-pulse family, quiet, right ear, room reverb
    for p in P1_pulse_single P2_pulse_accretion P3_pulse_arp P4_pulse_breath P5_pulse_urgency; do
      nf out/concepts/src/${p}_src.wav out/concepts/engine/${p}_earR.wav R 0.12 0.08
    done
    # a couple of space/level alternates to compare
    nf out/concepts/src/P2_pulse_accretion_src.wav out/concepts/engine/P2_pulse_accretion_earR_hall.wav R 0.12 0.08 hall 0.35
    nf out/concepts/src/P4_pulse_breath_src.wav    out/concepts/engine/P4_pulse_breath_earL.wav         L 0.12 0.08
    echo "-> out/concepts/engine/"
