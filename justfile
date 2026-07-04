# Antiphon top-level recipes. (Web recipes live in web/justfile, daemon in antiphond/justfile.)

# Bake the default HRTF + room asset (required once before render/native/web)
bake:
    cargo run -p antiphon-bake --release -- assets/baked/antiphon-default.antiphon

# Offline demo renders -> out/*.wav (the listening + parity oracle)
render:
    cargo run -p antiphon-render --release

# Run the Rust test suite
test:
    cargo test --release

# Native/wasm parity gate (run after any dsp/ffi change)
parity:
    cargo run -p antiphon-render --release -q -- parity
    cargo build -p antiphon-ffi --release --target wasm32-unknown-unknown
    node tools/parity.mjs

# Build the native macOS app
app:
    bash native/AntiphonApp/make.sh

# Build + launch the native macOS app
run: app
    open native/AntiphonApp/Antiphon.app

# Build the daemon
daemon:
    cd antiphond && go build -o bin/antiphond ./cmd/antiphond

# Rebuild wasm + stage assets into web/public
wasm:
    bash tools/build-web.sh

# Serve the marketing site + demo locally
serve:
    cd web && bun run dev

# Ship a CalVer release tag (stamps versions, commits, tags, pushes)
tag:
    bash tools/tag.sh

# ---- sound-design experiments (offline concept renders) ----------------------

# Generate ambient "agent waiting" sound-design concepts -> out/concepts/*.wav
concepts:
    uv run tools/sound_concepts.py

# Render one mono clip statically close to one ear, through the engine (near-field + reverb).
# usage: just nearfield in.wav out.wav [R|L] [dist] [gain] [room] [send]
nearfield IN OUT SIDE="R" DIST="0.12" GAIN="0.10" ROOM="room" SEND="0.30":
    cargo run -q -p antiphon-render --release -- nearfield {{IN}} {{OUT}} {{SIDE}} {{DIST}} {{GAIN}} {{ROOM}} {{SEND}}
