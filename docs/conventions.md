# Coordinate & data conventions

One canonical frame lives in `chamber-dsp`. Every host (native Swift, web JS) converts at
its edge. Pin these so left/right never flips.

## World / listener frame (right-handed)

- **+x = right**, **+y = up**, **+z = back**. **Front = −z.**
- Positions are world metres. The listener pose is `{position, orientation quaternion}`.
- A source's listener-relative direction is `inv(head_orientation) · (source_pos − head_pos)`.

## Spherical angles (HRTF grid)

- **Azimuth `az`** measured toward **+left**: `0` = front, `+π/2` = left, `−π/2` = right.
- **Elevation `el`**: `0` = ear level, `+π/2` = straight up.
- Unit vector for `(az, el)`: `[-cos(el)·sin(az), sin(el), -cos(el)·cos(az)]`
  (so `az=0,el=0 → (0,0,-1)` front; `az=-π/2 → (+1,0,0)` right). Defined once in
  `chamber-assets::AssetBuilder::push_direction` and `chamber-bake`.

## ITD sign

- Stored per direction in **fractional samples**. `itd > 0` means the source is toward the
  **left**, so the **right** ear is delayed by `itd`; `itd < 0` delays the left ear.

## Head pose from trackers

- **Native (Vision `FaceTracker`)**: `onOrient` yields a front-arc angle in degrees
  (−90…+90); the app maps it to yaw radians and builds `qw=cos(yaw/2), qy=sin(yaw/2)`.
- **Web (pointer / MediaPipe)**: yaw about +y, pitch about +x; same quaternion construction
  in `chamber-worklet.js`.

## Audio format

- Internal sample rate **48 kHz**; HRIRs baked at 48 k. Block size is flexible but the
  AudioWorklet quantum (and the recommended internal block) is **128 frames**.
- HRIRs are **minimum-phase**, **128 taps**; ITD is applied separately as a fractional delay.
