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

/// Talk-back dwell/lock hum: a barely-there loop on the agent's CHORD ROOT
/// (the drone's register). ONE continuous sound whose whole shape lives in the
/// engine's gain: it builds in slowly while the gaze dwells, leans up a touch
/// at the lock, and releases — never a second tone. Seamless: both oscillators
/// complete whole cycles over the loop.
func makeBloom(_ freq: Float, sr: Double = 48_000) -> [Float] {
    let dur = 2.0
    let n = Int(sr * dur)
    let f = (Double(freq) / 2 * dur).rounded() / dur // chord root, loop-quantized
    let f2 = f + 1.0 / dur // one extra cycle → a slow 0.5 Hz warmth
    var y = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let t = Double(i) / sr
        let s = sin(2 * .pi * f * t) * 0.62 + sin(2 * .pi * f2 * t) * 0.38
        y[i] = Float(s * 0.05)
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

/// The working drone: a low rumble of the chord's three lower tones (root,
/// minor third, fifth — the same register the tool notes walk through), each
/// undulating on its own slow rate so the whole thing rolls rather than
/// pulses. Seamless 4 s loop: every carrier and undulation completes whole
/// cycles.
func makeDrone(_ ping: Float, sr: Double = 48_000) -> [Float] {
    let dur = 4.0
    let n = Int(sr * dur)
    let root = (Double(ping) / 2 * dur).rounded() / dur
    let tones = [1.0, pow(2, 3.0 / 12), pow(2, 7.0 / 12)].map { (root * $0 * dur).rounded() / dur }
    let amps = [0.5, 0.26, 0.24] // root-heavy — it should sit low
    let rates = [0.25, 0.5, 0.75] // whole cycles over the loop
    let phases = [0.0, 2.1, 4.2]
    var y = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let t = Double(i) / sr
        var s = 0.0
        for k in 0..<3 {
            let roll = 0.7 + 0.3 * sin(2 * .pi * rates[k] * t + phases[k])
            s += sin(2 * .pi * tones[k] * t) * amps[k] * roll
        }
        y[i] = Float(s * 0.16)
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
