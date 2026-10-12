import AVFoundation
import LPCore

/// Pre-decoded sounds played through one audio engine, so a ping's sound starts with no noticeable delay.
///
/// Everything that touches the engine happens on a queue of its own. Starting the audio hardware takes a few hundred
/// milliseconds, and it has to be started again whenever nothing has played for a while; done on the main thread,
/// that is a wheel that hangs before it appears.
final class SoundBank {
    /// Safety ceiling: more overlapping sounds than this are skipped (the ping still shows).
    static let maxVoices = 8

    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    /// Serial. The engine, the players and everything below are used on it and nowhere else.
    private let queue = DispatchQueue(label: "lolping.audio", qos: .userInteractive)
    private var players: [AVAudioPlayerNode] = []
    private var busy: [Bool]
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var idleStop: DispatchWorkItem?
    private let loadQueue = DispatchQueue(label: "lolping.sounds", qos: .userInitiated)

    init() {
        busy = Array(repeating: false, count: Self.maxVoices)
        for _ in 0..<Self.maxVoices {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: format)
            players.append(p)
        }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            // The output device changed: the engine has stopped and restarts with the next sound.
            self?.queue.async { self?.busy = Array(repeating: false, count: Self.maxVoices) }
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
            self.queue.async {
                self.buffers.merge(decoded) { _, new in new }
                DispatchQueue.main.async(execute: completion)
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

    /// Starts the audio hardware ahead of the first sound (when a wheel opens). Returns at once; the hardware comes
    /// up in the background.
    func warmUp() {
        queue.async { self.start() }
    }

    /// Returns at once. After a quiet spell the sound follows as soon as the hardware is up again.
    func play(_ key: String, volume: Double) {
        guard volume > 0 else { return }
        queue.async {
            guard let buffer = self.buffers[key], let voice = self.busy.firstIndex(of: false) else { return }
            self.start()
            guard self.engine.isRunning else { return }
            let player = self.players[voice]
            self.busy[voice] = true
            player.volume = Float(min(1, volume))
            player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
                self.queue.async { self.busy[voice] = false }
            }
            player.play()
            self.scheduleIdleStop()
        }
    }

    #if DEBUG
    /// Development only: whether the hardware is up and how many sounds are playing, once the queue has caught up.
    func debugState() -> (running: Bool, playing: Int) {
        queue.sync { (engine.isRunning, players.filter(\.isPlaying).count) }
    }
    #endif

    // MARK: - On the audio queue

    private func start() {
        guard !engine.isRunning else { return }
        engine.prepare()
        try? engine.start()
        scheduleIdleStop()
    }

    /// Lets the audio hardware sleep when nothing has played for a while.
    private func scheduleIdleStop() {
        idleStop?.cancel()
        let stop = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.busy.contains(true) {
                self.scheduleIdleStop()
            } else {
                self.engine.pause()
            }
        }
        idleStop = stop
        queue.asyncAfter(deadline: .now() + 20, execute: stop)
    }
}
