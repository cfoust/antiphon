# Coordinate & data conventions

One canonical frame lives in `antiphon-dsp`. Every host (native Swift, web JS) converts at
its edge. Pin these so left/right never flips.

## World / listener frame (right-handed)

- **+x = right**, **+y = up**, **+z = back**. **Front = −z.**
- Positions are world metres. The listener pose is `{position, orientation quaternion}`.
- A source's listener-relative direction is `inv(head_orientation) · (source_pos − head_pos)`.
- **Room placement**: the world origin is the listener's nominal ear position. Rooms are
  x/z-centred on it, but vertically the ears sit `EAR_HEIGHT_M` (1.6 m, `antiphon-dsp`)
  above the floor: floor at `y = -EAR_HEIGHT_M`, ceiling at `y = dims[1] - EAR_HEIGHT_M`.

## Spherical angles (HRTF grid)

- **Azimuth `az`** measured toward **+left**: `0` = front, `+π/2` = left, `−π/2` = right.
- **Elevation `el`**: `0` = ear level, `+π/2` = straight up.
- Unit vector for `(az, el)`: `[-cos(el)·sin(az), sin(el), -cos(el)·cos(az)]`
  (so `az=0,el=0 → (0,0,-1)` front; `az=-π/2 → (+1,0,0)` right). Defined once in
  `antiphon-assets::AssetBuilder::push_direction` and `antiphon-bake`.

## ITD sign

- Stored per direction in **fractional samples**. `itd > 0` means the source is toward the
  **left**, so the **right** ear is delayed by `itd`; `itd < 0` delays the left ear.

## Source directivity (facing / pattern)

- `Source.facing` is a **world-space emission axis** (need not be unit length; the engine
  normalizes). The **zero vector means omnidirectional** — hosts that don't care pass zeros.
- `Source.directivity ∈ [0,1]`: 0 = omni (bit-exact with the pre-directivity engine),
  1 = cardioid-like. The pattern is **frequency-dependent**: at 1.0 the broadband rear
  level is −12 dB and the per-path one-pole coefficient falls to ×0.3 behind the source
  (HF beams harder than LF). See `directivity_gain` in `antiphon-dsp/src/lib.rs`.
- **Image sources mirror the facing axis**: each axis' component flips when that axis'
  bounce count is odd (parity of `bounces[2a]+bounces[2a+1]`) — the standard image-source
  treatment of a directional emitter. The energy-ranking proxy evaluates the pattern toward
  the **origin** (the listener's nominal spot) so it stays listener-independent (no slot
  reshuffles).
- The **reverb send is facing-compensated**: the pattern gain is divided back out of the
  send and replaced by the pattern's diffuse-field average (`1 − 0.42·d`), so total room
  energy doesn't depend on facing — behind a directional source you hear a higher wet/dry
  ratio, not a dead room.

## Source extent (volumetric size)

- `Source.extent` is a **radius in metres**, 0 = point source (bit-exact legacy path),
  clamped to 8 m. The direct path renders as the centre voice plus 4 satellite voices on a
  **fixed world-space tetrahedron** scaled by the radius, each fed through a deterministic
  velvet-noise decorrelator (~24 ms sparse FIR, unit energy, no feedback → parity- and
  denormal-safe), with a power-conserving gain split and true geometric pre-delay for
  satellites farther than the centre. Reflections and the late-reverb send treat the source
  as its centre point.

## Head pose from trackers

- **Native (Vision `FaceTracker`)**: `onOrient` yields a front-arc angle in degrees
  (−90…+90); the app maps it to yaw radians and builds `qw=cos(yaw/2), qy=sin(yaw/2)`.
- **Web (pointer / MediaPipe)**: yaw about +y, pitch about +x; same quaternion construction
  in `antiphon-worklet.js`.

## Audio format

- Internal sample rate **48 kHz**; HRIRs baked at 48 k. Block size is flexible but the
  AudioWorklet quantum (and the recommended internal block) is **128 frames**.
- HRIRs are **minimum-phase**, **128 taps**; ITD is applied separately as a fractional delay.
