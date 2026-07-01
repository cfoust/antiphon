# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy"]
# ///
"""
Sound-design concept generator for Chamber's "an agent is waiting" ambient cue.

Design brief (learned the hard way): a drifting near-ear whisper reads as a
predator. The rule is: abstract + warm + musical + diffuse = presence;
near-speech + lateral + approaching = threat. So every concept here is
non-vocal, warm, and centered/diffuse (no lateral "someone's beside you").

Three families, from the palette we settled on:
  A. Harmonic bloom-into-drone  -- an agent = a consonant partial joining a chord
  B. Wind chimes                -- N waiting agents = strike density / pitch count
  C. Felt piano                 -- soft mallet tone; the safe way to "build over time"

Output: out/concepts/*.wav (48 kHz stereo, matches the engine's rate).
Reproducible: fixed RNG seed. Peak-normalized to -3 dBFS; level-match by ear.
"""

import os
import wave
import numpy as np

SR = 48_000
OUT = os.path.join(os.path.dirname(__file__), os.pardir, "out", "concepts")
rng = np.random.default_rng(42)

# ---------------------------------------------------------------------------
# primitives
# ---------------------------------------------------------------------------

def t(dur):
    return np.arange(int(dur * SR)) / SR


def raised_cosine_attack(n, attack_s):
    """0->1 raised-cosine ramp of length attack_s, then hold at 1."""
    env = np.ones(n)
    a = min(int(attack_s * SR), n)
    if a > 0:
        env[:a] = 0.5 - 0.5 * np.cos(np.linspace(0, np.pi, a))
    return env


def fade(sig, fin=0.02, fout=0.2):
    n = len(sig)
    fi = min(int(fin * SR), n // 2)
    fo = min(int(fout * SR), n // 2)
    shape = (-1,) + (1,) * (sig.ndim - 1)  # broadcast over channels if stereo
    if fi:
        sig[:fi] *= np.linspace(0, 1, fi).reshape(shape)
    if fo:
        sig[-fo:] *= np.linspace(1, 0, fo).reshape(shape)
    return sig


def onepole_lp(x, cutoff):
    """Simple one-pole low-pass; cutoff in Hz."""
    a = np.exp(-2 * np.pi * cutoff / SR)
    y = np.empty_like(x)
    acc = 0.0
    b = 1 - a
    for i in range(len(x)):
        acc = b * x[i] + a * acc
        y[i] = acc
    return y


def air_bed(dur, level=0.02, cutoff=1200.0):
    """Very quiet lowpassed noise -- 'room is breathing' presence, not silence."""
    n = int(dur * SR)
    noise = rng.standard_normal(n)
    bed = onepole_lp(noise, cutoff)
    bed /= np.max(np.abs(bed)) + 1e-9
    lfo = 0.7 + 0.3 * np.sin(2 * np.pi * 0.08 * t(dur))  # slow breathing
    return bed * lfo * level


def partial(freq, dur, decay=None, phase=None, detune=0.0):
    """One sine partial. decay=None -> sustained; else exp time-constant (s)."""
    ph = rng.uniform(0, 2 * np.pi) if phase is None else phase
    x = t(dur)
    f = freq * (1 + detune)
    sig = np.sin(2 * np.pi * f * x + ph)
    if decay is not None:
        sig *= np.exp(-x / decay)
    return sig


def add(buf, sig, at_s):
    """Mix sig into buf starting at at_s seconds (bounds-safe)."""
    i = int(at_s * SR)
    j = min(i + len(sig), len(buf))
    if i < len(buf):
        buf[i:j] += sig[: j - i]


# ---------------------------------------------------------------------------
# instrument voices
# ---------------------------------------------------------------------------

def warm_note(freq, dur, decay, brightness=6, inharmonic=0.0, detune=0.004):
    """
    Additive tone with a couple of detuned voices for warmth/beating.
    inharmonic>0 stretches partials (piano-like); brightness = # partials.
    """
    sig = np.zeros(int(dur * SR))
    for n in range(1, brightness + 1):
        stretch = np.sqrt(1 + inharmonic * n * n)
        amp = 1.0 / (n ** 1.3)
        pdecay = decay / (1 + 0.6 * (n - 1))  # highs die faster
        for d in (-detune, detune):
            sig += amp * partial(freq * n * stretch, dur, decay=pdecay, detune=d)
    return sig / (np.max(np.abs(sig)) + 1e-9)


def felt_piano(freq, dur, decay=6.0):
    """Soft felted-piano note: inharmonic tone + a lowpassed hammer/felt thump."""
    tone = warm_note(freq, dur, decay, brightness=8, inharmonic=0.0007, detune=0.0015)
    # felt/hammer transient: short lowpassed noise burst
    hn = int(0.03 * SR)
    hammer = rng.standard_normal(hn) * np.exp(-np.linspace(0, 6, hn))
    hammer = onepole_lp(hammer, 900.0)
    hammer /= np.max(np.abs(hammer)) + 1e-9
    out = tone.copy()
    out[:hn] += 0.18 * hammer
    # overall softness
    out = onepole_lp(out, 3500.0)
    return out / (np.max(np.abs(out)) + 1e-9)


# free-bar modal ratios (struck metal rod) + per-mode amp/decay shaping
CHIME_RATIOS = np.array([1.0, 2.756, 5.404, 8.933])
CHIME_AMPS = np.array([1.0, 0.5, 0.28, 0.15])

def chime_strike(freq, dur=3.0, vel=1.0):
    sig = np.zeros(int(dur * SR))
    for r, a in zip(CHIME_RATIOS, CHIME_AMPS):
        dec = (dur * 0.5) / r  # higher modes ring shorter
        sig += a * partial(freq * r, dur, decay=dec)
    sig[: int(0.003 * SR)] *= np.linspace(0, 1, int(0.003 * SR))  # 3ms attack
    return vel * sig / (np.max(np.abs(sig)) + 1e-9)


# A major pentatonic, upper-mid register -- gentle, "safe" tuning
PENTA = np.array([440.0, 493.9, 554.4, 659.3, 740.0])


# ---------------------------------------------------------------------------
# stereo / output
# ---------------------------------------------------------------------------

def diffuse(mono, spread=0.008):
    """Centered but wide: decorrelate L/R by a tiny detune -> enveloping, not lateral."""
    n = len(mono)
    # cheap decorrelation: two slightly time/phase shifted copies
    d = int(spread * SR)
    l = mono.copy()
    r = np.concatenate([np.zeros(d), mono])[:n]
    return np.stack([l, r], axis=1)


def pan(mono, p):
    """Constant-power pan, p in [-1,1]. Kept modest for chimes."""
    ang = (p + 1) * np.pi / 4
    return np.stack([mono * np.cos(ang), mono * np.sin(ang)], axis=1)


def normalize(stereo, peak_db=-3.0):
    peak = np.max(np.abs(stereo)) + 1e-9
    target = 10 ** (peak_db / 20)
    return stereo * (target / peak)


def write_mono(name, mono, subdir="src", peak_db=-6.0):
    """Dry MONO source for the engine to spatialize (near-field render). No drone bed."""
    d = os.path.join(OUT, subdir)
    os.makedirs(d, exist_ok=True)
    mono = fade(mono.copy(), 0.02, 0.4)
    peak = np.max(np.abs(mono)) + 1e-9
    mono = mono * (10 ** (peak_db / 20) / peak)
    ints = (np.clip(mono, -1, 1) * 32767).astype("<i2")
    with wave.open(os.path.join(d, name), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(ints.tobytes())
    print(f"  src {name}  ({len(mono)/SR:.1f}s)")


def write(name, stereo):
    os.makedirs(OUT, exist_ok=True)
    stereo = fade(stereo, fin=0.02, fout=0.3)
    stereo = normalize(stereo)
    ints = (np.clip(stereo, -1, 1) * 32767).astype("<i2")
    path = os.path.join(OUT, name)
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(ints.tobytes())
    print(f"  wrote {name}  ({len(stereo)/SR:.1f}s)")


# ---------------------------------------------------------------------------
# Family A -- harmonic bloom-into-drone
# ---------------------------------------------------------------------------

def drone_partials(dur, freqs, amps):
    """Sustained warm drone from a set of frequencies (with beating + air)."""
    mono = np.zeros(int(dur * SR))
    lfo = 0.85 + 0.15 * np.sin(2 * np.pi * 0.1 * t(dur))
    for f, a in zip(freqs, amps):
        for d in (-0.004, 0.004):  # detuned pair -> slow beating
            mono += a * partial(f, dur, detune=d)
    mono *= lfo
    mono += air_bed(dur, level=0.03)
    return mono / (np.max(np.abs(mono)) + 1e-9)


def A1_third_bloom():
    # A2 root + E3 fifth drone; C#3 major third blooms in at t=3s over 4s
    dur = 13
    base = drone_partials(dur, [110.0, 164.8], [1.0, 0.6])
    thirdmono = np.zeros(int(dur * SR))
    for f, a in ((138.6, 0.7), (277.2, 0.35)):
        thirdmono += a * partial(f, dur)
    env = np.zeros(int(dur * SR))
    seg = raised_cosine_attack(len(env) - int(3 * SR), 4.0)
    env[int(3 * SR):] = seg
    mono = base + 0.5 * thirdmono * env
    write("A1_drone_third_bloom.wav", diffuse(mono / (np.max(np.abs(mono)) + 1e-9)))


def A2_rhodes_arp_bloom():
    # drone + a soft Rhodes-y arpeggio (root, fifth, octave, third) resolving in
    dur = 13
    mono = drone_partials(dur, [110.0, 164.8], [1.0, 0.55])
    notes = [(220.0, 4.0), (329.6, 5.2), (440.0, 6.4), (277.2, 7.6)]
    for f, at in notes:
        note = warm_note(f, 4.0, decay=1.8, brightness=4)
        trem = 1 + 0.08 * np.sin(2 * np.pi * 5 * t(4.0))  # Rhodes tremolo
        add(mono, 0.35 * note * trem, at)
    write("A2_drone_rhodes_arp_bloom.wav", diffuse(mono / (np.max(np.abs(mono)) + 1e-9)))


def A3_chord_accretion():
    # 3 agents arrive in sequence -> chord thickens: +3rd, +octave, +7th
    dur = 16
    mono = drone_partials(dur, [110.0, 164.8], [1.0, 0.55])
    arrivals = [(138.6, 4.0, 0.5), (220.0, 8.0, 0.45), (207.65, 12.0, 0.4)]  # C#3, A3, G#3(maj7)
    for f, at, amp in arrivals:
        p = np.zeros(int(dur * SR))
        seg_n = len(p) - int(at * SR)
        body = partial(f, dur - at) + 0.4 * partial(2 * f, dur - at)
        env = raised_cosine_attack(seg_n, 2.5)
        add(mono, amp * body * env, at)
    write("A3_chord_accretion_1-2-3.wav", diffuse(mono / (np.max(np.abs(mono)) + 1e-9)))


def A4_shimmer_swell():
    # drone with a high consonant partial that slowly swells and settles (anticipation, resolved)
    dur = 13
    mono = drone_partials(dur, [110.0, 164.8, 220.0], [1.0, 0.5, 0.3])
    high = partial(659.3, dur) + 0.5 * partial(988.0, dur)  # E5 + B5 shimmer
    swell = 0.5 - 0.5 * np.cos(2 * np.pi * (1 / (2 * dur)) * t(dur))  # up then implied settle
    swell = np.clip(swell * 1.4, 0, 1)
    mono += 0.18 * high * swell
    write("A4_drone_shimmer_swell.wav", diffuse(mono / (np.max(np.abs(mono)) + 1e-9)))


# ---------------------------------------------------------------------------
# Family B -- wind chimes (N = number of waiting agents)
# ---------------------------------------------------------------------------

def chimes(dur, n_agents, per_agent_rate=0.5, pitches=None, seed_pan=True):
    """Poisson strikes; total rate scales with n_agents, clustered on wind gusts."""
    mono_L = np.zeros(int(dur * SR))
    stereo = np.zeros((int(dur * SR), 2))
    pitches = PENTA if pitches is None else pitches
    # slow smooth 'wind gust' envelope modulating strike probability
    gust_ctrl = onepole_lp(rng.standard_normal(int(dur * SR)), 0.4)
    gust_ctrl = (gust_ctrl - gust_ctrl.min()) / (np.ptp(gust_ctrl) + 1e-9)
    rate = n_agents * per_agent_rate
    # walk time, drawing exponential gaps, accept by gust probability
    time_s = 0.0
    while time_s < dur - 0.5:
        gap = rng.exponential(1.0 / rate)
        time_s += gap
        if time_s >= dur - 0.5:
            break
        if rng.random() > 0.35 + 0.65 * gust_ctrl[int(time_s * SR)]:
            continue
        freq = pitches[rng.integers(len(pitches))]
        vel = rng.uniform(0.5, 1.0)
        strike = chime_strike(freq, dur=3.0, vel=vel)
        p = rng.uniform(-0.45, 0.45) if seed_pan else 0.0
        st = pan(strike, p)
        i = int(time_s * SR)
        j = min(i + len(strike), len(stereo))
        stereo[i:j] += st[: j - i]
    return stereo


def B_family():
    for n in (1, 3, 5):
        st = chimes(15, n)
        write(f"B{ {1:1,3:2,5:3}[n] }_chimes_N{n}.wav".replace(" ", ""), st)
    # each agent = distinct pitch, so you can *count* by ear (4 agents, 4 pitches)
    four = np.array([440.0, 554.4, 659.3, 880.0])
    st = chimes(15, 4, per_agent_rate=0.45, pitches=four)
    write("B4_chimes_pitch_identity.wav", st)


# ---------------------------------------------------------------------------
# Family C -- felt piano
# ---------------------------------------------------------------------------

def C1_single_tone():
    dur = 11
    mono = np.zeros(int(dur * SR))
    add(mono, felt_piano(220.0, 9.0, decay=6.0), 0.3)  # A3
    write("C1_felt_single_tone.wav", diffuse(mono, spread=0.004))


def C2_arpeggio():
    dur = 12
    mono = np.zeros(int(dur * SR))
    notes = [(220.0, 0.5), (277.2, 1.4), (329.6, 2.3), (440.0, 3.2), (329.6, 4.3)]
    for f, at in notes:
        add(mono, 0.8 * felt_piano(f, dur - at, decay=5.0), at)
    write("C2_felt_arpeggio.wav", diffuse(mono, spread=0.004))


def C3_tone_into_drone():
    # felt A3 strike, with a soft A2 drone fading in beneath and sustaining
    dur = 13
    mono = np.zeros(int(dur * SR))
    add(mono, 0.9 * felt_piano(220.0, 10.0, decay=6.0), 0.3)
    drone = drone_partials(dur, [110.0, 164.8], [0.8, 0.45])
    env = raised_cosine_attack(len(drone), 5.0)
    mono += 0.45 * drone * env
    write("C3_felt_tone_into_drone.wav", diffuse(mono / (np.max(np.abs(mono)) + 1e-9)))


def C4_urgency_ramp():
    # THE core mechanic, safe timbre: a felt note repeating, slowly building presence
    # over 22s. Starts sparse/quiet/dark -> ends closer/brighter/more frequent.
    dur = 22
    mono = np.zeros(int(dur * SR))
    time_s = 0.5
    while time_s < dur - 1.0:
        u = time_s / dur  # 0..1 urgency
        interval = 4.0 * (1 - u) + 1.1 * u  # 4.0s -> 1.1s
        amp = 0.25 + 0.75 * u
        decay = 5.0 + 2.0 * u
        note = felt_piano(220.0 * (1 + 0.0 * u), dur - time_s, decay=decay)
        # brighten with urgency by mixing in an octave that grows in
        note = note + 0.35 * u * felt_piano(440.0, dur - time_s, decay=decay * 0.7)
        note /= np.max(np.abs(note)) + 1e-9
        add(mono, amp * note, time_s)
        time_s += interval
    write("C4_felt_urgency_ramp.wav", diffuse(mono / (np.max(np.abs(mono)) + 1e-9), spread=0.004))


# ---------------------------------------------------------------------------
# Engine sources: DRY MONO, drone stripped -- fed to `chamber-render nearfield`
# so the real engine places them at the ear with the near-field DVF. The events
# (the arpeggio bloom / the accreting chord) are the whole signal now; no bed.
# ---------------------------------------------------------------------------

def A2_src():
    # A2 reworked: just the resolving Rhodes arpeggio, two gentle passes, NO drone.
    dur = 12
    mono = np.zeros(int(dur * SR))
    seq = [220.0, 329.6, 440.0, 277.2] * 2       # root, fifth, octave, major third
    starts = [0.6, 1.7, 2.8, 3.9, 6.8, 7.9, 9.0, 10.1]
    for f, at in zip(seq, starts):
        seg = min(3.5, dur - at)
        note = warm_note(f, seg, decay=1.9, brightness=4)
        trem = 1 + 0.08 * np.sin(2 * np.pi * 5 * t(seg))   # Rhodes tremolo
        add(mono, 0.5 * note * trem, at)
    write_mono("A2_rhodes_src.wav", mono)


def A3_src():
    # A3 reworked: three agents arrive and each blooms in and *stays* -- the chord
    # accretes from silence, no constant root+fifth pad underneath.
    dur = 16
    mono = np.zeros(int(dur * SR))
    arrivals = [(220.0, 1.0, 0.55), (277.2, 6.0, 0.46), (329.6, 11.0, 0.40)]  # root, maj3, 5th
    for f, at, amp in arrivals:
        seg = dur - at
        x = t(seg)
        body = (partial(f, seg, detune=-0.003) + partial(f, seg, detune=0.003)
                + 0.4 * partial(2 * f, seg) + 0.2 * partial(3 * f, seg))
        env = raised_cosine_attack(len(body), 2.8)             # slow bloom-in
        swell = 1 + 0.22 * np.sin(2 * np.pi * (1.0 / (2.0 * seg)) * x)  # gentle 'roar' then settle
        add(mono, amp * body * env * swell, at)
    write_mono("A3_accretion_src.wav", mono)


# ---------------------------------------------------------------------------
# Recurring-pulse family: instead of a held chord, each "agent waiting" is a soft
# tone that BLOOMS then FADES toward silence, recurring on a slow cycle. Reads as a
# gentle heartbeat of presence, not a drone. (Rendered through reverb by the engine.)
# ---------------------------------------------------------------------------

def pulse_note(freq, dur_note, attack=0.8, decay=2.2,
               partials=(1, 2, 3), amps=(1.0, 0.4, 0.2)):
    """One bloom-then-fade tone: raised-cosine attack, exponential decay to silence."""
    n = int(dur_note * SR)
    x = t(dur_note)
    sig = np.zeros(n)
    for p, a in zip(partials, amps):
        for det in (-0.003, 0.003):  # slight detune -> warmth
            sig += a * partial(freq * p, dur_note, detune=det)
    env = np.ones(n)
    ai = min(int(attack * SR), n)
    if ai:
        env[:ai] = 0.5 - 0.5 * np.cos(np.linspace(0, np.pi, ai))
    env *= np.exp(-np.maximum(0.0, x - attack) / decay)
    return sig * env / (np.max(np.abs(sig * env)) + 1e-9)


def P1_pulse_single_src():
    # one agent: a single warm tone blooming and fading every 4 s
    dur = 20
    mono = np.zeros(int(dur * SR))
    tt = 0.5
    while tt < dur - 3:
        add(mono, 0.5 * pulse_note(220.0, 3.5, attack=0.9, decay=2.2), tt)
        tt += 4.0
    write_mono("P1_pulse_single_src.wav", mono)


def P2_pulse_accretion_src():
    # A3 as a pulse: the chord accretes, but the whole chord blooms+fades each cycle
    dur = 24
    mono = np.zeros(int(dur * SR))
    def chord(tt):
        f = [220.0]
        if tt >= 8:  f.append(277.2)   # + major third (agent 2)
        if tt >= 16: f.append(329.6)   # + fifth (agent 3)
        return f
    tt = 0.5
    while tt < dur - 3:
        for f in chord(tt):
            add(mono, 0.4 * pulse_note(f, 3.5, attack=1.0, decay=2.4), tt)
        tt += 4.0
    write_mono("P2_pulse_accretion_src.wav", mono)


def P3_pulse_arp_src():
    # A2 as a pulse: a quick soft Rhodes arpeggio blooms each cycle
    dur = 20
    mono = np.zeros(int(dur * SR))
    arp = [220.0, 329.6, 440.0, 277.2]
    tt = 0.5
    while tt < dur - 3:
        for i, f in enumerate(arp):
            add(mono, 0.4 * pulse_note(f, 2.4, attack=0.05, decay=1.4,
                                       partials=(1, 2), amps=(1.0, 0.3)), tt + i * 0.18)
        tt += 4.5
    write_mono("P3_pulse_arp_src.wav", mono)


def P4_pulse_breath_src():
    # the "barely there" end: a very slow bloom (2.5 s attack) that breathes every 6.5 s
    dur = 24
    mono = np.zeros(int(dur * SR))
    tt = 0.5
    while tt < dur - 5:
        add(mono, 0.5 * pulse_note(220.0, 6.0, attack=2.5, decay=3.5,
                                   partials=(1, 2), amps=(1.0, 0.3)), tt)
        tt += 6.5
    write_mono("P4_pulse_breath_src.wav", mono)


def P5_pulse_urgency_src():
    # the core mechanic: pulses get faster, louder, richer as urgency builds over 26 s
    dur = 26
    mono = np.zeros(int(dur * SR))
    tt = 0.5
    while tt < dur - 3:
        u = tt / dur
        freqs = [220.0]
        if u > 0.35: freqs.append(277.2)
        if u > 0.70: freqs.append(329.6)
        amp = 0.3 + 0.45 * u
        for f in freqs:
            add(mono, amp * pulse_note(f, 3.0, attack=max(0.15, 1.0 * (1 - u)), decay=2.0), tt)
        tt += 5.0 * (1 - u) + 1.6 * u  # 5.0 s -> 1.6 s
    write_mono("P5_pulse_urgency_src.wav", mono)


# ---------------------------------------------------------------------------

INDEX = """# Sound-design concepts -- "an agent is waiting" ambient cue

Listen on headphones. All centered/diffuse (no lateral drift). Level-match by ear.

## A -- Harmonic bloom-into-drone  (agent = a consonant partial joining the chord)
- A1_drone_third_bloom      root+fifth drone; a major third blooms in ~4s = one agent ready
- A2_drone_rhodes_arp_bloom  drone + a soft Rhodes arpeggio resolving in
- A3_chord_accretion_1-2-3   three agents arrive in sequence; the chord thickens each time
- A4_drone_shimmer_swell     drone + a high shimmer that swells and settles (anticipation)

## B -- Wind chimes  (N waiting agents = strike density; clustered on 'wind gusts')
- B1_chimes_N1   one agent waiting
- B2_chimes_N3   three agents waiting
- B3_chimes_N5   five agents waiting
- B4_chimes_pitch_identity   four agents, each a distinct pitch (count them by ear)

## C -- Felt piano  (soft mallet tone; the safe way to 'build over time')
- C1_felt_single_tone     one soft note
- C2_felt_arpeggio        gentle warm arpeggio
- C3_felt_tone_into_drone  a felt note that sustains into a soft drone (crossover)
- C4_felt_urgency_ramp     THE core mechanic: a felt note slowly building presence over 22s
"""


def main():
    os.makedirs(OUT, exist_ok=True)
    print("Family A -- harmonic bloom-into-drone")
    A1_third_bloom(); A2_rhodes_arp_bloom(); A3_chord_accretion(); A4_shimmer_swell()
    print("Family B -- wind chimes (N agents)")
    B_family()
    print("Family C -- felt piano")
    C1_single_tone(); C2_arpeggio(); C3_tone_into_drone(); C4_urgency_ramp()
    print("Engine sources (dry mono, drone stripped) -> concepts/src/")
    A2_src(); A3_src()
    print("Recurring-pulse sources -> concepts/src/")
    P1_pulse_single_src(); P2_pulse_accretion_src(); P3_pulse_arp_src()
    P4_pulse_breath_src(); P5_pulse_urgency_src()
    with open(os.path.join(OUT, "INDEX.md"), "w") as f:
        f.write(INDEX)
    print(f"\nDone -> {os.path.relpath(OUT)}  (see INDEX.md)")


if __name__ == "__main__":
    main()
