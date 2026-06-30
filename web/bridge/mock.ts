/**
 * Scripted fake-agent scenario — drives the whole chamber chain (bridge -> page) with
 * no Claude session, so you can iterate on audio + UX. Two agents work in parallel and
 * finish. Run the bridge and the page (?live) first, then: `just chamber-demo`.
 * Pass `--fast` to compress the timing for stress-testing the queue / drop-stale.
 */
const BASE = process.env.CHAMBER_BASE || "http://127.0.0.1:8787";
const fast = process.argv.includes("--fast");
const GAP = fast ? 700 : 2600;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function emit(seat: number, type: string, text?: string): Promise<void> {
  await fetch(`${BASE}/debug/emit`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ seat, type, text }),
  }).catch((e) => console.error("emit failed — is the bridge running?", e));
}

async function run(
  seat: number,
  headline: string,
  steps: string[],
  summary: string,
  startDelay: number,
): Promise<void> {
  await sleep(startDelay);
  await emit(seat, "bind");
  await emit(seat, "task", headline);
  for (const s of steps) {
    await sleep(GAP);
    await emit(seat, "progress", s);
  }
  await sleep(GAP);
  await emit(seat, "done", summary);
}

console.log(`[mock] driving ${BASE} (${fast ? "fast" : "real-time"})`);
await Promise.all([
  run(
    0,
    "reworking the auth token flow",
    [
      "Pulling the auth module apart now — the token refresh keeps deadlocking.",
      "Found it: the middleware grabs the lock twice. Patching that.",
      "Running the whole suite again. Green so far.",
      "Just checking the edge case where the token expires mid-request.",
    ],
    "The auth refactor's done and the suite is green. I left the session store alone until you give me the word.",
    0,
  ),
  run(
    1,
    "chasing the flaky test",
    [
      "Tracing the failing test backwards from the assertion.",
      "Two keys collapse to the same hash — that's the flake.",
      "Added a tiebreaker on the identifier. Looping it a hundred times to be sure.",
    ],
    "Found the flake — two keys hashed to the same value, so I added a tiebreaker. Ran it a hundred times clean.",
    1200,
  ),
]);
console.log("[mock] scenario complete");
