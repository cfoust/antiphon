import AVFoundation
import Foundation

// Buffer helpers: load the ElevenLabs voices, synthesize the earcons (ping/chime) and the
// radio static, and offline-filter a "whispered" (high-passed, breathy) copy of each voice.
// Everything is produced as 48 kHz mono and exposed as `[Float]` so the Chamber render
// callback can mix raw samples and hand mono buffers to the Rust binaural engine.

let mono48 = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
let SAMPLE_RATE: Double = 48_000

/// Extract channel 0 of a PCM buffer into a plain `[Float]`.
func samples(_ buf: AVAudioPCMBuffer) -> [Float] {
    let n = Int(buf.frameLength)
    guard let p = buf.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: p, count: n))
}

func loadMono(_ url: URL) -> [Float]? {
    guard let file = try? AVAudioFile(forReading: url) else { return nil }
    let inFmt = file.processingFormat
    let cap = AVAudioFrameCount(file.length)
    guard cap > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: cap) else { return nil }
    do { try file.read(into: inBuf) } catch { return nil }
    if inFmt.sampleRate == SAMPLE_RATE, inFmt.channelCount == 1 { return samples(inBuf) }
    guard let conv = AVAudioConverter(from: inFmt, to: mono48) else { return samples(inBuf) }
    let outCap = AVAudioFrameCount(Double(cap) * SAMPLE_RATE / inFmt.sampleRate + 4_096)
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: mono48, frameCapacity: outCap) else { return samples(inBuf) }
    var fed = false
    _ = conv.convert(to: outBuf, error: nil) { _, status in
        if fed { status.pointee = .noDataNow; return nil }
        fed = true; status.pointee = .haveData; return inBuf
    }
    return samples(outBuf)
}

/// RBJ biquad over a fresh copy.
private func biquad(_ x: [Float], b0: Float, b1: Float, b2: Float, a0: Float, a1: Float, a2: Float) -> [Float] {
    var y = [Float](repeating: 0, count: x.count)
    let nb0 = b0 / a0, nb1 = b1 / a0, nb2 = b2 / a0, na1 = a1 / a0, na2 = a2 / a0
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
    for i in 0..<x.count {
        let xn = x[i]
        let yn = nb0 * xn + nb1 * x1 + nb2 * x2 - na1 * y1 - na2 * y2
        x2 = x1; x1 = xn; y2 = y1; y1 = yn
        y[i] = yn
    }
    return y
}

/// Breathy whisper: strip the voiced low end with a high-pass (matches the web engine).
func whispered(_ src: [Float], cutoff: Float = 900, sr: Float = 48_000) -> [Float] {
    let w0 = 2 * Float.pi * cutoff / sr
    let cw = cos(w0), sw = sin(w0)
    let alpha = sw / (2 * 0.707)
    return biquad(src,
                  b0: (1 + cw) / 2, b1: -(1 + cw), b2: (1 + cw) / 2,
                  a0: 1 + alpha, a1: -2 * cw, a2: 1 - alpha)
}

func makePing(_ freq: Float, sr: Double = 48_000) -> [Float] {
    let n = Int(sr * 0.6)
    var y = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let t = Double(i) / sr
        let env = exp(-t * 7.0)
        let s = sin(2 * .pi * Double(freq) * t) * 0.5 + sin(2 * .pi * Double(freq) * 1.5 * t) * 0.22
        y[i] = Float(s * env)
    }
    return y
}

func makeChime(sr: Double = 48_000) -> [Float] {
    let n = Int(sr * 0.5)
    var y = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let t = Double(i) / sr
        var s = 0.0
        s += sin(2 * .pi * 587.33 * t) * 0.34 * exp(-t * 6)
        if t >= 0.1 { let t2 = t - 0.1; s += sin(2 * .pi * 880.0 * t2) * 0.34 * exp(-t2 * 6) }
        y[i] = Float(s)
    }
    return y
}

/// Talk-back dwell bloom: a soft swell that rises over ~1.2 s, built on the agent's ping
/// frequency so the light "belongs" to the voice. The rising envelope is baked in — the
/// dwell state machine only gates the gain, and an aborted dwell just fades it out.
func makeBloom(_ freq: Float, sr: Double = 48_000) -> [Float] {
    let dur = 1.2
    let n = Int(sr * dur)
    var y = [Float](repeating: 0, count: n)
    var lp: Double = 0 // one-pole low-pass over noise → breathy air, no hiss edge
    var seed: UInt64 = 0x9e3779b97f4a7c15
    for i in 0..<n {
        let t = Double(i) / sr
        let p = min(1.0, t / dur)
        let env = p * p * (3 - 2 * p) // smoothstep swell
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let white = Double(Int64(bitPattern: seed >> 11)) / Double(Int64.max)
        lp += (white - lp) * 0.035
        let f = Double(freq) * 0.5
        let tone = sin(2 * .pi * f * t) * 0.55 + sin(2 * .pi * f * 2.005 * t) * 0.2
        let shimmer = 0.85 + 0.15 * sin(2 * .pi * 5.3 * t)
        y[i] = Float((tone * shimmer + lp * 2.4) * env * 0.28)
    }
    return y
}

/// Talk-back lock chime: two gentle partials a major third apart, softer and rounder than
/// the accept chime — "I'm with you now", not "task complete".
func makeLockChime(_ freq: Float, sr: Double = 48_000) -> [Float] {
    let n = Int(sr * 0.8)
    var y = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let t = Double(i) / sr
        var s = sin(2 * .pi * Double(freq) * t) * 0.30 * exp(-t * 4.5)
        if t >= 0.11 {
            let t2 = t - 0.11
            s += sin(2 * .pi * Double(freq) * 1.25 * t2) * 0.30 * exp(-t2 * 4.5)
        }
        y[i] = Float(s)
    }
    return y
}

// MARK: chord identity (tool calls + working drone)
//
// Each agent's chord is a minor-7th built an octave below its ping frequency:
// tool calls walk DOWN the chord's top three tones (m7 → 5th → m3), one gentle
// note per call, and the chord's root is the agent's working drone — a quiet,
// slowly breathing tone that says "this direction is busy" without words.

/// The three descending tool-call notes for a ping frequency (Hz, high→low).
func toolNoteFreqs(_ ping: Float) -> [Float] {
    let root = ping / 2
    return [root * powf(2, 10 / 12), root * powf(2, 7 / 12), root * powf(2, 3 / 12)]
}

/// One tool-call note: a soft, round pluck — sine + a whisper of octave.
func makeToolNote(_ freq: Float, sr: Double = 48_000) -> [Float] {
    let n = Int(sr * 0.9)
    var y = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let t = Double(i) / sr
        let env = min(t / 0.008, 1) * exp(-t * 4.2)
        let s = sin(2 * .pi * Double(freq) * t) * 0.85
              + sin(2 * .pi * Double(freq) * 2 * t) * 0.10
        y[i] = Float(s * env * 0.16)
    }
    return y
}

/// The working drone: a seamless 4 s loop of the chord root, breathing at
/// 0.5 Hz with a 0.25 Hz two-oscillator beat. All components complete whole
/// cycles over the loop so it can run forever without a click.
func makeDrone(_ ping: Float, sr: Double = 48_000) -> [Float] {
    let dur = 4.0
    let n = Int(sr * dur)
    // quantize the carrier to whole cycles over the loop (seamless)
    let f = (Double(ping) / 2 * dur).rounded() / dur
    let f2 = f + 1.0 / dur // exactly one extra cycle → a slow, warm beat
    var y = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let t = Double(i) / sr
        let breathe = 0.62 + 0.38 * sin(2 * .pi * 0.5 * t - .pi / 2)
        let s = sin(2 * .pi * f * t) * 0.6 + sin(2 * .pi * f2 * t) * 0.4
        y[i] = Float(s * breathe * 0.16)
    }
    return y
}

/// Drag audition pulse: a sonar-ish blip once per 1.4 s loop, meant to be
/// played with a hot reverb send so the room answers from the agent's spot.
func makePulse(_ ping: Float, sr: Double = 48_000) -> [Float] {
    let dur = 1.4
    let n = Int(sr * dur)
    let f = (Double(ping) * dur).rounded() / dur
    var y = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let t = Double(i) / sr
        let env = min(t / 0.006, 1) * exp(-t * 5.5)
        let s = sin(2 * .pi * f * t) * 0.7 + sin(2 * .pi * f / 2 * t) * 0.3
        y[i] = Float(s * env * 0.5)
    }
    return y
}

/// 2s of band-passed noise — a weak tuned signal rather than broadband hiss.
func makeStatic(sr: Double = 48_000) -> [Float] {
    let n = Int(sr * 2)
    var noise = [Float](repeating: 0, count: n)
    for i in 0..<n { noise[i] = Float.random(in: -1...1) }
    let f: Float = 1_400, q: Float = 3.5
    let w0 = 2 * Float.pi * f / Float(sr)
    let cw = cos(w0), sw = sin(w0)
    let alpha = sw / (2 * q)
    return biquad(noise, b0: alpha, b1: 0, b2: -alpha, a0: 1 + alpha, a1: -2 * cw, a2: 1 - alpha)
}
