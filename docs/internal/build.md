# Building

## Toolchains
- **Rust**: `rustup default stable && rustup target add wasm32-unknown-unknown`.
- **Swift** (native app only): Command Line Tools `swiftc` is sufficient — no Xcode, no
  SwiftPM. If `swiftc` errors about a duplicate `SwiftBridging` module, remove the stale
  CLT modulemap (one-time): `sudo mv /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap{,.disabled}`.
  Full Xcode is only needed later for Developer ID signing / notarization.

## One-time: bake the HRTF asset
```sh
cargo run -p antiphon-bake --release -- assets/baked/antiphon-default.antiphon
```
Produces the `.antiphon` blob (analytic structural HRTF grid + 4 room presets). A measured
SOFA importer can replace the analytic model behind the same output format later.

## Offline demos (audible quality check)
```sh
cargo run -p antiphon-render --release            # writes out/*.wav
```

## Native macOS app
```sh
bash native/AntiphonApp/make.sh                   # -> native/AntiphonApp/AntiphonApp.app
open native/AntiphonApp/AntiphonApp.app
```
Builds the Rust staticlib, links it into the Swift app with `swiftc -L/-l` (no SwiftPM),
copies the asset into the bundle, and ad-hoc codesigns.

## Web (WASM) demo
```sh
bash tools/build-web.sh                           # builds wasm + stages web/
python3 -m http.server -d web 8080                # open http://localhost:8080
```
Single-threaded AudioWorklet → no SharedArrayBuffer, no COOP/COEP headers needed.

## Cross-target parity test
```sh
cargo run -p antiphon-render --release -- parity   # native reference
cargo build -p antiphon-ffi --release --target wasm32-unknown-unknown
node tools/parity.mjs                             # asserts native≈wasm < -90 dBFS
```

## Tests
```sh
cargo test --release
```
