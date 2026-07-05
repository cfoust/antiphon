import CoreAudio
import AudioToolbox
import Foundation

// System-audio capture (scratch/system-audio-tap.md): a Core Audio process tap
// (macOS 14.4+) captures a stereo mixdown of everything the Mac plays EXCEPT
// our own process, muting the originals at the device. We become the only path
// to the headphones for that audio, so "deaden" and "spatialize" are just two
// things the engine does before re-emitting it. Destroying the tap (or the
// process dying) un-mutes the tapped apps — the whole design fails open.

/// Lock-free SPSC ring of interleaved stereo frames. Producer = tap IOProc,
/// consumer = the engine render callback; plain Int head/tail counters follow
/// the codebase's benign-race convention (aligned word loads on arm64).
final class StereoRing {
    private let capacity: Int // frames, power of two
    private let mask: Int
    private let buf: UnsafeMutablePointer<Float> // interleaved LR
    private var head = 0 // written frames (producer)
    private var tail = 0 // read frames (consumer)

    init(capacityFrames: Int) {
        var c = 1
        while c < capacityFrames { c <<= 1 }
        capacity = c
        mask = c - 1
        buf = .allocate(capacity: c * 2)
        buf.initialize(repeating: 0, count: c * 2)
    }
    deinit { buf.deallocate() }

    var fill: Int { max(0, head - tail) }

    /// Producer. Drops the oldest audio when full — capture must never block.
    func push(_ L: UnsafePointer<Float>, _ R: UnsafePointer<Float>, _ n: Int) {
        if fill + n > capacity { tail = head + n - capacity } // overwrite oldest
        for i in 0..<n {
            let w = ((head + i) & mask) * 2
            buf[w] = L[i]
            buf[w + 1] = R[i]
        }
        head += n
    }

    /// Consumer. Pops what it has; zero-fills the shortfall.
    func pop(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ n: Int) {
        let have = min(n, fill)
        for i in 0..<have {
            let r = ((tail + i) & mask) * 2
            L[i] = buf[r]
            R[i] = buf[r + 1]
        }
        if have < n {
            L.advanced(by: have).update(repeating: 0, count: n - have)
            R.advanced(by: have).update(repeating: 0, count: n - have)
        }
        tail += have
    }
}

/// Captures all system audio except Antiphon itself, muting the originals at
/// the device. Owns: tap → private aggregate device → IOProc → 48 kHz ring.
@available(macOS 14.4, *)
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private let ring = StereoRing(capacityFrames: 24_000) // ~500 ms at 48 k
    private var srcRate: Double = 48_000
    // linear-interp resampler state (capture thread only)
    private var rsPos: Double = 0
    private var rsLastL: Float = 0
    private var rsLastR: Float = 0
    // deinterleave/resample scratch, capture thread only (no per-callback allocation)
    private var scratchL = [Float](repeating: 0, count: 8192)
    private var scratchR = [Float](repeating: 0, count: 8192)
    private var rsOutL = [Float](repeating: 0, count: 9216)
    private var rsOutR = [Float](repeating: 0, count: 9216)
    // device churn: default-output changes (AirPods, unplug, wake) invalidate
    // the aggregate's clock and can change the tap's rate — rebuild on our own
    // serial queue. The ring survives rebuilds, so pull() never notices.
    private let rebuildQ = DispatchQueue(label: "dev.antiphon.systap.rebuild")
    private var routeListener: AudioObjectPropertyListenerBlock?
    private var dead = false

    init?() {
        guard build() else { return nil }
        installRouteListener()
    }

    /// Builds tap → aggregate → IOProc. `rebuildQ` (or init). Returns false on
    /// permission denial or OS refusal.
    private func build() -> Bool {
        // 1. Our own process object — excluded so we never capture our binaural
        //    output back into itself (feedback loop).
        var me = AudioObjectID(kAudioObjectUnknown)
        var pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                         UInt32(MemoryLayout<pid_t>.size), &pid,
                                         &size, &me) == noErr,
              me != kAudioObjectUnknown else { return false }

        // 2. The tap: stereo mixdown of everything else, muting the originals
        //    at the device. First creation fires the one-time TCC prompt.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [me])
        desc.muteBehavior = CATapMuteBehavior.mutedWhenTapped
        desc.isPrivate = true
        desc.name = "Antiphon system tap"
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr,
              tapID != kAudioObjectUnknown else { return false }

        // 3. A private aggregate containing the default output (for the clock)
        //    plus the tap; its IOProc's input buffers are the tapped audio.
        let outUID = Self.defaultOutputUID() ?? ""
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Antiphon System Tap",
            kAudioAggregateDeviceUIDKey: "dev.antiphon.systap." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: outUID.isEmpty ? [] :
                [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey:
                [[kAudioSubTapDriftCompensationKey: 1,
                  kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg) == noErr else {
            teardownCore(); return false
        }
        aggID = agg

        // 4. Taps deliver at the output device's rate; note it for resampling.
        if let fmt = Self.tapFormat(tapID) { srcRate = fmt.mSampleRate }

        // 5. IOProc: deinterleave → resample to 48 k → ring. Never blocks.
        let err = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggID, nil) {
            [weak self] _, inData, _, _, _ in
            self?.capture(inData)
        }
        guard err == noErr, let proc = ioProc,
              AudioDeviceStart(aggID, proc) == noErr else {
            teardownCore(); return false
        }
        NSLog("[antiphon] system tap live (source %.0f Hz)", srcRate)
        return true
    }

    /// Default-output route changes → rebuild the whole capture path. TCC is
    /// already granted, so rebuilds never prompt.
    private func installRouteListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !self.dead else { return }
            NSLog("[antiphon] output route changed — rebuilding system tap")
            self.teardownCore()
            usleep(200_000) // let the new route settle before re-tapping
            if self.dead { return }
            if !self.build() { NSLog("[antiphon] system tap rebuild failed") }
        }
        routeListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                            &addr, rebuildQ, block)
    }

    deinit { teardown() }


    /// Render thread: fills exactly n frames of 48 kHz stereo, zero-filling on
    /// underrun (silence is the correct failure mode).
    func pull(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ n: Int) {
        ring.pop(L, R, n)
    }

    /// Full stop: no more rebuilds, listener removed, Mac audio restored.
    func teardown() {
        dead = true
        if let block = routeListener {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &addr, rebuildQ, block)
            routeListener = nil
        }
        rebuildQ.sync { } // drain any in-flight rebuild
        teardownCore()
    }

    private func teardownCore() {
        if let p = ioProc {
            AudioDeviceStop(aggID, p)
            AudioDeviceDestroyIOProcID(aggID, p)
            ioProc = nil
        }
        if aggID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggID)
            aggID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            // destroying the tap un-mutes the tapped apps — fail-open by design
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: capture thread

    private func capture(_ inData: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard abl.count >= 1, let d0 = abl[0].mData else { return }
        var n = 0
        if abl.count >= 2, abl[0].mNumberChannels == 1, let d1 = abl[1].mData {
            // non-interleaved stereo
            n = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
            n = min(n, scratchL.count)
            scratchL.withUnsafeMutableBufferPointer {
                $0.baseAddress!.update(from: d0.assumingMemoryBound(to: Float.self), count: n)
            }
            scratchR.withUnsafeMutableBufferPointer {
                $0.baseAddress!.update(from: d1.assumingMemoryBound(to: Float.self), count: n)
            }
        } else {
            // interleaved (channel count from the buffer; mono duplicates)
            let ch = max(1, Int(abl[0].mNumberChannels))
            let total = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
            n = min(total / ch, scratchL.count)
            let p = d0.assumingMemoryBound(to: Float.self)
            for i in 0..<n {
                scratchL[i] = p[i * ch]
                scratchR[i] = ch > 1 ? p[i * ch + 1] : p[i * ch]
            }
        }
        guard n > 0 else { return }

        if abs(srcRate - 48_000) < 0.5 {
            scratchL.withUnsafeBufferPointer { lp in
                scratchR.withUnsafeBufferPointer { rp in
                    ring.push(lp.baseAddress!, rp.baseAddress!, n)
                }
            }
            return
        }
        // linear resample srcRate → 48 k, with a slow ratio trim driven by ring
        // fill so the two clock domains can't walk the buffer off a cliff
        let half = Double(12_000)
        let trim = 1.0 + 2e-4 * (Double(ring.fill) - half) / half
        let step = (srcRate / 48_000) * trim
        var m = 0
        while rsPos < Double(n), m < rsOutL.count {
            let i = Int(rsPos)
            let f = Float(rsPos - Double(i))
            let l0 = i == 0 ? rsLastL : scratchL[i - 1]
            let r0 = i == 0 ? rsLastR : scratchR[i - 1]
            // interpolate between the previous and current source samples
            rsOutL[m] = l0 + (scratchL[i] - l0) * f
            rsOutR[m] = r0 + (scratchR[i] - r0) * f
            m += 1
            rsPos += step
        }
        rsPos -= Double(n)
        if rsPos < 0 { rsPos = 0 }
        rsLastL = scratchL[n - 1]
        rsLastR = scratchR[n - 1]
        if m > 0 {
            rsOutL.withUnsafeBufferPointer { lp in
                rsOutR.withUnsafeBufferPointer { rp in
                    ring.push(lp.baseAddress!, rp.baseAddress!, m)
                }
            }
        }
    }

    // MARK: property helpers

    private static func defaultOutputUID() -> String? {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                         0, nil, &size, &dev) == noErr else { return nil }
        var uid: Unmanaged<CFString>?
        var usize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &usize, &uid) == noErr,
              let u = uid else { return nil }
        return u.takeRetainedValue() as String
    }

    private static func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var fmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &fmt) == noErr else { return nil }
        return fmt
    }
}
