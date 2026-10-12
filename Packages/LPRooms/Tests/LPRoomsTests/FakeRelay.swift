import Foundation
import Network
@testable import LPRooms

/// Just enough of a Nostr relay for tests, on loopback: subscriptions by kind and "#x" tag, OK for every event, and
/// each event sent to every matching subscription, the author's included. `since` and `limit` are ignored: nothing
/// is stored. (Upstream's tests/main/fixtures/fakeRelay.ts, on Network.framework instead of the ws package.)
///
/// For testing the socket itself it also obeys ["TEST", "binary" | "huge" | "close"].
final class FakeRelay {
    private struct Filter {
        var kinds: [Int]
        var topics: [String]
    }

    private final class Client {
        let connection: NWConnection
        var subs: [String: Filter] = [:]

        init(_ connection: NWConnection) {
            self.connection = connection
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-relay")
    private var clients: [ObjectIdentifier: Client] = [:]
    private(set) var port: UInt16 = 0
    /// Events it was sent, for tests that look at what reached the relay.
    private(set) var received: [NostrEvent] = []

    var url: String { "ws://127.0.0.1:\(port)" }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 8 << 20
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    func close() {
        queue.sync {
            for c in clients.values { c.connection.cancel() }
            clients.removeAll()
            listener.cancel()
        }
    }

    var eventCount: Int { queue.sync { received.count } }

    private func accept(_ connection: NWConnection) {
        let client = Client(connection)
        clients[ObjectIdentifier(client)] = client
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .failed, .cancelled: self.clients[ObjectIdentifier(client)] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        receive(client)
    }

    private func receive(_ client: Client) {
        client.connection.receiveMessage { [weak self, weak client] data, context, _, error in
            guard let self, let client, error == nil else { return }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if meta?.opcode == .close {
                client.connection.cancel()
                return
            }
            if meta?.opcode == .text, let data { self.handle(client, String(decoding: data, as: UTF8.self)) }
            self.receive(client)
        }
    }

    private func send(_ client: Client, _ text: String) {
        send(client, Data(text.utf8), .text)
    }

    private func send(_ client: Client, _ data: Data, _ opcode: NWProtocolWebSocket.Opcode) {
        let meta = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [meta])
        client.connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func handle(_ client: Client, _ text: String) {
        guard let m = JSON.parse(text)?.array, let type = m.first?.string else { return }
        switch type {
        case "REQ":
            guard m.count >= 3, let sub = m[1].string, let f = m[2].object else { return }
            client.subs[sub] = Filter(kinds: f["kinds"]?.array?.compactMap(\.integer) ?? [], topics: f["#x"]?.array?.compactMap(\.string) ?? [])
            send(client, "[\"EOSE\",\(JSON.quote(sub))]")
        case "CLOSE":
            if m.count >= 2, let sub = m[1].string { client.subs[sub] = nil }
        case "EVENT":
            guard case .event(_, let e)? = Nostr.parseRelayMessage("[\"EVENT\",\"s\",\(text.dropFirst(9))") else { return }
            received.append(e)
            send(client, "[\"OK\",\"\(e.id)\",true,\"\"]")
            let json = Nostr.eventMessage(e).dropFirst(9)
            for peer in clients.values {
                for (sub, f) in peer.subs where f.kinds.contains(e.kind) && e.tags.contains(where: { $0.count >= 2 && $0[0] == "x" && f.topics.contains($0[1]) }) {
                    send(peer, "[\"EVENT\",\(JSON.quote(sub)),\(json)")
                }
            }
        case "TEST":
            switch m.count >= 2 ? m[1].string : nil {
            case "binary": send(client, Data([1, 2, 3]), .binary)
            case "huge": send(client, "[\"NOTICE\",\"" + String(repeating: "x", count: 2 << 20) + "\"]")
            case "close": client.connection.cancel()
            case "echo": send(client, "[\"NOTICE\",\"echo\"]")
            default: break
            }
        default:
            break
        }
    }
}
