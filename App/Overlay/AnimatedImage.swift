import AppKit
import ImageIO

/// The frames of an animated WebP, GIF or APNG, decoded on a background queue while the animation already plays.
/// A still image is one frame.
final class FrameDecoder {
    private let source: CGImageSource
    let count: Int
    /// When each frame starts, in seconds from the first; one more entry for the total length.
    let startTimes: [Double]
    private var frames: [CGImage] = []
    private let lock = NSLock()
    private var cancelled = false
    private static let queue = DispatchQueue(label: "lolping.frames", qos: .userInitiated, attributes: .concurrent)

    var duration: Double { startTimes.last ?? 0 }

    init?(data: Data) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let n = CGImageSourceGetCount(src)
        guard n > 0 else { return nil }
        source = src
        count = n
        var t = 0.0
        var starts = [0.0]
        for i in 0..<n {
            t += n > 1 ? Self.delay(src, i) : 0
            starts.append(t)
        }
        startTimes = starts
    }

    private static func delay(_ src: CGImageSource, _ i: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] else { return 0.1 }
        let tables: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
        ]
        for (dict, unclamped, clamped) in tables {
            guard let d = props[dict] as? [CFString: Any] else { continue }
            if let v = d[unclamped] as? Double, v > 0 { return v }
            if let v = d[clamped] as? Double, v > 0 { return v }
        }
        return 0.1
    }

    /// Starts decoding from the first frame. Frames become available in order.
    func start() {
        Self.queue.async { [self] in
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            for i in 0..<count {
                lock.lock()
                let stop = cancelled
                lock.unlock()
                if stop { return }
                guard let frame = CGImageSourceCreateImageAtIndex(source, i, options) else { return }
                lock.lock()
                frames.append(frame)
                lock.unlock()
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        frames.removeAll()
        lock.unlock()
    }

    /// The frame for `time` seconds into the animation, or the newest one decoded so far when decoding is behind.
    func frame(at time: Double) -> CGImage? {
        var index = 0
        while index + 1 < count && startTimes[index + 1] <= time { index += 1 }
        lock.lock()
        defer { lock.unlock() }
        if frames.isEmpty { return nil }
        return frames[min(index, frames.count - 1)]
    }
}

/// Shows a `FrameDecoder`'s animation in a layer, once or looping.
final class FramePlayer {
    private let decoder: FrameDecoder
    private weak var layer: CALayer?
    private let loops: Bool
    private var timer: Timer?
    private var startedAt: CFTimeInterval = 0
    private var shown: CGImage?
    /// Called once if the first frame can't be decoded.
    var onFailure: (() -> Void)?

    init(decoder: FrameDecoder, layer: CALayer, loops: Bool) {
        self.decoder = decoder
        self.layer = layer
        self.loops = loops
    }

    func start() {
        decoder.start()
        startedAt = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        decoder.cancel()
    }

    private func tick() {
        guard let layer else { return stop() }
        var elapsed = CACurrentMediaTime() - startedAt
        if loops && decoder.duration > 0 { elapsed = elapsed.truncatingRemainder(dividingBy: decoder.duration) }
        guard let frame = decoder.frame(at: elapsed) else {
            if elapsed > 1 { // nothing after a second: the file can't be decoded
                stop()
                onFailure?()
            }
            return
        }
        if frame !== shown {
            shown = frame
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = frame
            CATransaction.commit()
        }
    }
}
