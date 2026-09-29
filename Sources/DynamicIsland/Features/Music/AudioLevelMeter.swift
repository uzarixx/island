import Accelerate
import CoreAudio
import Foundation
import os

/// The music app's sound split into frequency bands for the equalizer. Listens to that app alone through
/// a Core Audio process tap (macOS 14.2+); nothing is recorded or kept. Only with the setting on
/// (see `AppSettings.liveEqualizerEnabled`): macOS asks for audio capture permission the first
/// time and shows its purple recording dot while the tap runs. Without permission the tap hears
/// silence and the equalizer keeps its made-up animation.
///
/// The tap runs only while the app plays. Samples are analyzed on a background queue into target
/// levels; the equalizer eases toward them each frame it draws (see `levels(at:)`), so the bars
/// move smoothly however the audio arrives, and nothing is published to SwiftUI.
final class AudioLevelMeter: @unchecked Sendable {
    static let shared = AudioLevelMeter()
    static let bandCount = 6

    /// The app whose sound is tapped (see `MusicApp`); main thread only.
    private var bundleID = MusicApp.spotify.bundleID

    /// Band edges in Hz, spaced evenly on a log scale like hearing: from bass to treble.
    private static let bandEdges: [Float] = [40, 100, 250, 600, 1500, 4000, 10000]
    private static let fftSize = 1024
    /// How quickly each band's usual level and swing adapt to the music, per analysis
    /// (about 90 a second): roughly the last second counts.
    private static let adaptRate: Float = 0.012
    /// Below this, in dB, a band is treated as silent and its bar stays down.
    private static let silenceFloor: Float = -20

    /// How fast the bars follow the sound, in seconds: up with a beat, gently back down.
    private static let riseTime: Float = 0.045
    private static let fallTime: Float = 0.16

    private struct Shared {
        /// The latest analysis.
        var targets = [Float](repeating: 0, count: AudioLevelMeter.bandCount)
        /// What the bars show, eased toward `targets` as frames are drawn.
        var displayed = [Float](repeating: 0, count: AudioLevelMeter.bandCount)
        var lastFrame = Date.distantPast
        /// Real sound has come through at least once: capture is allowed and works.
        var hasSignal = false
    }

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let queue = DispatchQueue(label: "AudioLevelMeter", qos: .userInteractive)

    // Tap objects; touched on the main thread only.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isActive = false
    private var isPlaying = false
    private var retryTask: Task<Void, Never>?

    // Analysis state; touched on `queue` only.
    private var sampleRate: Float = 48000
    private var pending: [Float] = []
    /// Each band's usual level in dB and how far it usually swings from it, over the last second
    /// or so. Bars show how far the sound is from usual right now, so they move with the beat
    /// however loud or compressed the music is. nil until the first analysis after starting.
    private var means: [Float]?
    private var swings = [Float](repeating: 3, count: AudioLevelMeter.bandCount)
    private let fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(AudioLevelMeter.fftSize))), radix: .radix2, ofType: DSPSplitComplex.self)
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: AudioLevelMeter.fftSize, isHalfWindow: false)
    private var real = [Float](repeating: 0, count: AudioLevelMeter.fftSize / 2)
    private var imag = [Float](repeating: 0, count: AudioLevelMeter.fftSize / 2)
    private var magnitudes = [Float](repeating: 0, count: AudioLevelMeter.fftSize / 2)

    /// Band levels 0...1 from bass to treble for a frame drawn at `date`; nil until real sound
    /// has been heard. Easing by the time since the last frame keeps the motion even whatever
    /// the frame rate.
    func levels(at date: Date) -> [Float]? {
        shared.withLock { state in
            guard state.hasSignal else { return nil }
            let elapsed = Float(min(0.1, max(0, date.timeIntervalSince(state.lastFrame))))
            state.lastFrame = date
            for band in 0..<Self.bandCount {
                let target = state.targets[band]
                let time = target > state.displayed[band] ? Self.riseTime : Self.fallTime
                state.displayed[band] += (target - state.displayed[band]) * (1 - exp(-elapsed / time))
            }
            return state.displayed
        }
    }

    // MARK: - Starting and stopping

    /// Taps the music app while it plays, if the setting is on; call from the main thread.
    func setPlaying(_ playing: Bool, bundleID: String) {
        if bundleID != self.bundleID {
            // Another app: a running tap listens to the old one.
            self.bundleID = bundleID
            if isActive {
                isActive = false
                retryTask?.cancel()
                retryTask = nil
                stop()
            }
        }
        isPlaying = playing
        apply()
    }

    /// Starts or stops the tap after the setting changes; call from the main thread.
    func apply() {
        let active = isPlaying && AppSettings.liveEqualizerEnabled
        guard active != isActive else { return }
        isActive = active
        retryTask?.cancel()
        retryTask = nil
        if active { start(attemptsLeft: 5) } else { stop() }
        // Turned off: back to the made-up animation right away.
        if !AppSettings.liveEqualizerEnabled { shared.withLock { $0.hasSignal = false } }
    }

    private func start(attemptsLeft: Int) {
        guard #available(macOS 14.2, *), isActive else { return }
        let processes = Self.processes(of: bundleID)
        // The app may not have opened its audio output yet right after starting to play.
        guard !processes.isEmpty, startTap(processes: processes) else {
            stop()
            guard attemptsLeft > 1 else { return }
            retryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.start(attemptsLeft: attemptsLeft - 1)
            }
            return
        }
    }

    @available(macOS 14.2, *)
    private func startTap(processes: [AudioObjectID]) -> Bool {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = "Island equalizer"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { return false }

        guard let format: AudioStreamBasicDescription = AudioObject.property(tapID, kAudioTapPropertyFormat),
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32,
              let outputUID = Self.defaultOutputUID()
        else { return false }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Island equalizer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else { return false }

        let rate = Float(format.mSampleRate)
        queue.async { [self] in
            sampleRate = rate
            pending.removeAll(keepingCapacity: true)
            means = nil
        }
        shared.withLock { $0.targets = $0.targets.map { _ in 0 } }

        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.receive(input)
        }
        guard status == noErr, AudioDeviceStart(aggregateID, ioProcID) == noErr else { return false }
        return true
    }

    private func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        // The bars settle down instead of freezing where they were.
        shared.withLock { $0.targets = $0.targets.map { _ in 0 } }
    }

    // MARK: - Analysis (on `queue`)

    private func receive(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let buffer = buffers.first, let data = buffer.mData else { return }
        let channels = max(1, Int(buffer.mNumberChannels))
        let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        let samples = data.assumingMemoryBound(to: Float.self)

        // Mix interleaved channels down to mono; non-interleaved audio uses the first channel.
        var loudest: Float = 0
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels { sum += samples[frame * channels + channel] }
            let sample = sum / Float(channels)
            loudest = max(loudest, abs(sample))
            pending.append(sample)
        }
        if loudest > 1e-4, !shared.withLock({ $0.hasSignal }) {
            shared.withLock { $0.hasSignal = true }
        }

        // Half-overlapping windows: about 90 analyses a second at 48 kHz.
        while pending.count >= Self.fftSize {
            analyze(pending[0..<Self.fftSize])
            pending.removeFirst(Self.fftSize / 2)
        }
    }

    private func analyze(_ samples: ArraySlice<Float>) {
        guard let fft else { return }
        let windowed = vDSP.multiply(samples, window)
        real.withUnsafeMutableBufferPointer { realPointer in
            imag.withUnsafeMutableBufferPointer { imagPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { pointer in
                    pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.fftSize / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.fftSize / 2))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP.squareMagnitudes(split, result: &magnitudes)
            }
        }

        let binWidth = sampleRate / Float(Self.fftSize)
        let decibels = (0..<Self.bandCount).map { band in
            let low = max(1, Int(Self.bandEdges[band] / binWidth))
            let high = min(magnitudes.count, max(low + 1, Int(Self.bandEdges[band + 1] / binWidth)))
            return 10 * log10(vDSP.mean(magnitudes[low..<high]) + 1e-12)
        }
        var means = self.means ?? decibels

        var levels = [Float](repeating: 0, count: Self.bandCount)
        for band in 0..<Self.bandCount {
            let deviation = decibels[band] - means[band]
            means[band] += deviation * Self.adaptRate
            swings[band] += (abs(deviation) - swings[band]) * Self.adaptRate
            guard decibels[band] > Self.silenceFloor else { continue }

            // Usual level sits a bit below the middle; a hit about two usual swings above it
            // fills the bar, a dip as far below empties it. The swing has a floor, so a steady
            // tone doesn't turn tiny wobbles into full jumps.
            let score = deviation / max(swings[band], 1.5)
            levels[band] = min(1, max(0, 0.4 + 0.3 * score))
        }
        self.means = means
        let targets = levels
        shared.withLock { $0.targets = targets }
    }

    // MARK: - Core Audio properties

    private static func processes(of bundleID: String) -> [AudioObjectID] {
        let processes: [AudioObjectID] = AudioObject.array(AudioObject.system, kAudioHardwarePropertyProcessObjectList)
        return processes.filter { process in
            // The app's helpers ("com.spotify.client.helper") may be the ones playing.
            AudioObject.string(process, kAudioProcessPropertyBundleID)?.hasPrefix(bundleID) == true
        }
    }

    private static func defaultOutputUID() -> String? {
        guard let device: AudioObjectID = AudioObject.property(AudioObject.system, kAudioHardwarePropertyDefaultSystemOutputDevice),
              let uid = AudioObject.string(device, kAudioDevicePropertyDeviceUID)
        else { return nil }
        return uid
    }
}
