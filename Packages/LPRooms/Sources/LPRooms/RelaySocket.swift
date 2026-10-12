import Foundation

public enum RelaySocketMessage: Equatable, Sendable {
    case text(String)
    /// A binary frame, or one too large to take: no Nostr relay sends either.
    case unacceptable
}

/// The slice of a WebSocket the relay code uses. Handlers run on the transport's queue; after `close()` none runs.
public protocol RelaySocket: AnyObject {
    var onOpen: (() -> Void)? { get set }
    var onMessage: ((RelaySocketMessage) -> Void)? { get set }
    /// The relay or the network closed it, or it failed.
    var onClose: (() -> Void)? { get set }
    /// Throws when the socket isn't open.
    func send(_ text: String) throws
    func close()
}

/// Opens a socket to a relay URL. Throws for a URL no socket can be opened to.
public typealias RelaySocketFactory = (String) throws -> RelaySocket

public enum RelaySocketError: Error {
    case badURL
    case notOpen
}

/// WebSockets from URLSession, one session for all of them.
public final class URLSessionRelaySockets: NSObject, URLSessionWebSocketDelegate {
    /// Above upstream's 64 KB limit on a relay message, so that limit is the one that decides.
    private static let maxFrame = 1 << 20

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var sockets: [Int: Socket] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.httpShouldSetCookies = false
        // Our own timers decide when a relay is too slow (10 s to connect, 25 s without an echo), not URLSession's.
        config.timeoutIntervalForRequest = 3600
        let delegates = OperationQueue()
        delegates.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: delegates)
    }()

    /// The sockets of the app: handlers on the main queue. (A URLSession keeps its delegate for good, so one is shared.)
    public static let main = URLSessionRelaySockets(queue: .main)

    /// `queue` is where the sockets' handlers run.
    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    public var factory: RelaySocketFactory {
        { [self] url in try open(url) }
    }

    private func open(_ text: String) throws -> RelaySocket {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "wss" || scheme == "ws",
              let host = url.host, !host.isEmpty else { throw RelaySocketError.badURL }
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = Self.maxFrame
        let socket = Socket(task: task, queue: queue)
        lock.lock()
        sockets[task.taskIdentifier] = socket
        lock.unlock()
        task.resume()
        return socket
    }

    private func socket(_ task: URLSessionTask, remove: Bool = false) -> Socket? {
        lock.lock()
        defer { lock.unlock() }
        return remove ? sockets.removeValue(forKey: task.taskIdentifier) : sockets[task.taskIdentifier]
    }

    public func urlSession(_: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol _: String?) {
        socket(webSocketTask)?.opened()
    }

    public func urlSession(_: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith _: URLSessionWebSocketTask.CloseCode, reason _: Data?) {
        socket(webSocketTask)?.ended()
    }

    public func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError _: Error?) {
        socket(task, remove: true)?.ended()
    }

    /// One WebSocket. Its state is only touched on `queue`.
    private final class Socket: RelaySocket {
        var onOpen: (() -> Void)?
        var onMessage: ((RelaySocketMessage) -> Void)?
        var onClose: (() -> Void)?
        private let task: URLSessionWebSocketTask
        private let queue: DispatchQueue
        private var isOpen = false
        /// Closed by us, or reported closed: nothing is emitted any more.
        private var done = false

        init(task: URLSessionWebSocketTask, queue: DispatchQueue) {
            self.task = task
            self.queue = queue
        }

        func send(_ text: String) throws {
            guard isOpen, !done else { throw RelaySocketError.notOpen }
            task.send(.string(text)) { _ in } // a failed send shows up as the socket closing
        }

        func close() {
            if done { return }
            done = true
            isOpen = false
            // After whatever was sent: a bye written just before still goes out ahead of the close frame.
            task.cancel(with: .normalClosure, reason: nil)
        }

        func opened() {
            queue.async { [self] in
                if done || isOpen { return }
                isOpen = true
                onOpen?()
                receive()
            }
        }

        func ended() {
            queue.async { [self] in
                if done { return }
                done = true
                isOpen = false
                task.cancel()
                onClose?()
            }
        }

        /// One message at a time: the next is asked for only after this one was handled, so a relay that floods us
        /// fills its own socket, not our queue.
        private func receive() {
            task.receive { [weak self] result in
                guard let self else { return }
                self.queue.async { self.received(result) }
            }
        }

        private func received(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
            if done { return }
            switch result {
            case .success(.string(let text)):
                onMessage?(.text(text))
            case .success:
                onMessage?(.unacceptable)
            case .failure(let error as NSError) where error.domain == NSPOSIXErrorDomain && error.code == Int(EMSGSIZE):
                onMessage?(.unacceptable)
            case .failure:
                done = true
                isOpen = false
                task.cancel()
                onClose?()
                return
            }
            if !done { receive() }
        }
    }
}
