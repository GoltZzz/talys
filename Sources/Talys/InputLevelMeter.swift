import AVFoundation
import Observation

/// Live level of the default input device, sampled only while the audio panel is open.
@Observable
@MainActor
final class InputLevelMeter {
    static let shared = InputLevelMeter()

    enum Access { case unknown, granted, denied }

    /// Smoothed level in 0...1 (a -60…0 dBFS window).
    private(set) var level: Float = 0
    /// Recent peak that holds briefly, then falls back toward the level.
    private(set) var peak: Float = 0
    private(set) var access: Access = .unknown
    /// True while the default mic is Bluetooth: metering it would drop the headset into call-quality audio.
    private(set) var pausedForBluetooth = false

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var configObserver: NSObjectProtocol?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var peakHeldAt = Date.distantPast

    private init() {}

    func start() {
        guard !running else { return }
        running = true
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            access = .granted
            startEngine()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    let meter = InputLevelMeter.shared
                    meter.access = granted ? .granted : .denied
                    if granted, meter.running { meter.startEngine() }
                }
            }
        default:
            access = .denied
        }
    }

    func stop() {
        running = false
        stopEngine()
        level = 0
        peak = 0
    }

    /// Re-evaluates the meter after the default input device changes.
    func inputDeviceChanged() {
        if running, access == .granted { startEngine() }
    }

    private func startEngine() {
        stopEngine()
        pausedForBluetooth = AudioController.defaultInputIsBluetooth()
        if pausedForBluetooth {
            level = 0
            peak = 0
            return
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTap())
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            print("[InputLevelMeter] Could not start input engine: \(error)")
            return
        }
        self.engine = engine
        // Switching the default mic reconfigures the engine; rebuild on the new device.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let meter = InputLevelMeter.shared
                if meter.running { meter.startEngine() }
            }
        }
    }

    private func stopEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func ingest(_ sample: Float) {
        // Fast attack, slow release, so speech reads as a steady bar instead of flicker.
        level = sample > level ? sample : level * 0.82 + sample * 0.18
        let now = Date()
        if level >= peak {
            peak = level
            peakHeldAt = now
        } else if now.timeIntervalSince(peakHeldAt) > 0.9 {
            peak = max(level, peak - 0.015)
        }
    }

    /// Built outside the main actor: the tap runs on CoreAudio's realtime thread.
    nonisolated private static func makeTap() -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let samples = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            var sum: Float = 0
            for i in 0..<count { sum += samples[i] * samples[i] }
            let db = 20 * log10(max(sqrt(sum / Float(count)), 1e-7))
            let normalized = max(0, min(1, (db + 60) / 60))
            DispatchQueue.main.async {
                MainActor.assumeIsolated { InputLevelMeter.shared.ingest(normalized) }
            }
        }
    }
}
