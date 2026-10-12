import AVFoundation
import LPCore

/// Pre-decoded sounds played through one audio engine, so a ping's sound starts with no noticeable delay.
final class SoundBank {
    /// Safety ceiling: more overlapping sounds than this are skipped (the ping still shows).
    static let maxVoices = 8

    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private var players: [AVAudioPlayerNode] = []
    private var busy: [Bool]
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var idleTimer: Timer?
    private let loadQueue = DispatchQueue(label: "lolping.sounds", qos: .userInitiated)

    init() {
        busy = Array(repeating: false, count: Self.maxVoices)
        for _ in 0..<Self.maxVoices {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: format)
            players.append(p)
        }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            // The output device changed: the engine has stopped and restarts with the next sound.
            self?.busy = Array(repeating: false, count: Self.maxVoices)
        }
    }

    /// Decodes every bundled sound up front, each under its key ("SRP_12", "emote:nice"). Calls back on the main queue.
    func loadBundled(completion: @escaping () -> Void) {
        var entries: [(String, URL)] = []
        for name in PingCatalog.soundNames {
            if let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "sounds") { entries.append((name, url)) }
        }
        for e in EmoteCatalog.all where e.hasSound {
            if let url = Bundle.main.url(forResource: e.slug, withExtension: "m4a", subdirectory: "emotes") { entries.append(("emote:\(e.slug)", url)) }
        }
        let format = self.format
        loadQueue.async {
            var decoded: [String: AVAudioPCMBuffer] = [:]
            for (key, url) in entries {
                if let buffer = Self.decode(url, to: format) { decoded[key] = buffer }
            }
            DispatchQueue.main.async {
                self.buffers.merge(decoded) { _, new in new }
                completion()
            }
        }
    }

    private static func decode(_ url: URL, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: source)) != nil else { return nil }
        if file.processingFormat == format { return source }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else { return nil }
        let ratio = format.sampleRate / file.processingFormat.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(source.frameLength) * ratio) + 1024) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return source
        }
        return status == .error ? nil : out
    }

    /// Starts the audio hardware ahead of the first sound (when a wheel opens).
    func warmUp() {
        guard !engine.isRunning else { return }
        engine.prepare()
        try? engine.start()
        scheduleIdleStop()
    }

    func play(_ key: String, volume: Double) {
        guard volume > 0, let buffer = buffers[key], let voice = busy.firstIndex(of: false) else { return }
        warmUp()
        guard engine.isRunning else { return }
        let player = players[voice]
        busy[voice] = true
        player.volume = Float(min(1, volume))
        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.busy[voice] = false }
        }
        player.play()
        scheduleIdleStop()
    }

    /// Lets the audio hardware sleep when nothing has played for a while.
    private func scheduleIdleStop() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.busy.contains(true) {
                self.scheduleIdleStop()
            } else {
                self.engine.pause()
            }
        }
    }
}
