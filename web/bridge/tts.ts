/**
 * ElevenLabs text-to-speech. Flash for the frequent progress lines (low latency),
 * the quality multilingual model for identity + summary (where the voice matters).
 * The key is read from the repo's .env (Bun auto-loads it); it never reaches the page.
 * If the key is missing or a call fails we return null and the chamber runs silent —
 * seats, spatialization and the state machine still work for offline testing.
 */
export const FLASH = "eleven_flash_v2_5";
export const QUALITY = "eleven_multilingual_v2";

const KEY = process.env.ELEVENLABS_API_KEY;
let warned = false;

export async function synth(
  voice: string,
  text: string,
  model: string,
): Promise<Uint8Array | null> {
  if (!KEY) {
    if (!warned) {
      warned = true;
      console.warn(
        "[chamber] ELEVENLABS_API_KEY not set — running silent (seats + state still work).",
      );
    }
    return null;
  }
  try {
    const r = await fetch(
      `https://api.elevenlabs.io/v1/text-to-speech/${voice}?output_format=mp3_44100_128`,
      {
        method: "POST",
        headers: { "xi-api-key": KEY, "content-type": "application/json" },
        body: JSON.stringify({
          text,
          model_id: model,
          voice_settings: { stability: 0.5, similarity_boost: 0.75 },
        }),
      },
    );
    if (!r.ok) {
      console.error("[chamber] TTS", r.status, (await r.text()).slice(0, 200));
      return null;
    }
    return new Uint8Array(await r.arrayBuffer());
  } catch (e) {
    console.error("[chamber] TTS fetch failed", e);
    return null;
  }
}
