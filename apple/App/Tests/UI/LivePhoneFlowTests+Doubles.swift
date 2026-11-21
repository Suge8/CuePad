#if os(iOS)
import CryptoKit
import CueStore
import CueTestSupport
import Foundation
import Network
import os
import Testing
@testable import CuePad

extension LivePhoneFlowTests {
    final class Mac: VoiceSignaling {
        let local = VoiceEndpoint(device: .init("phone-live"), lease: UUID())
        let endpoint = VoiceEndpoint(device: .init(LivePhoneFlowTests.mac), lease: UUID())
        let key = SymmetricKey(size: .bits256)
        var ticket = Data()
        var pages: [URL] = []
        var found: [URL]?
        var sent: LiveAddress?
        var door: (addresses: [LiveTunnel.Address], port: UInt16)?
        var opened = false
        var present = true
        var connected = true
        var drops = false
        var revealed: [String] = []
        var returned: [String] = []
        var bounces = 0
        var showing = Showing.sends
        enum Showing { case sends, fails, hangs }
        private var held: [CheckedContinuation<Void, Never>] = []

        func letGo() {
            held.forEach { $0.resume() }
            held = []
        }
        private var server: LiveTunnel.Server?
        private let shown = OSAllocatedUnfairLock<Set<UInt16>>(initialState: [])

        func allow(_ url: URL) { shown.withLock { _ = $0.insert(UInt16(url.port!)) } }

        func openDoor(to port: UInt16) async throws {
            server?.cancel()
            let ticket = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            let shown = shown
            let server = try LiveTunnel.Server(key: key) { request in
                guard request.ticket == ticket else { return .ticket }
                if request.port == 0 { return .probe }
                return shown.withLock { $0.contains(request.port) } ? .open(host: "127.0.0.1", port: port) : .refused
            }
            door = ([.init(host: "127.0.0.1", prefix: 8)], try await server.start())
            self.ticket = ticket
            self.server = server
        }

        func close() { server?.cancel() }
        var answer: (VoiceRelayEvent) -> Void = { _ in }
        var voiceAvailability: VoiceRelayAvailability { connected ? .ready(endpoint: local) : .unavailable }
        var voiceEvents: AsyncStream<VoiceRelayEvent> { AsyncStream { _ in } }
        var liveTunnelKey: SymmetricKey? { key }

        func resolveVoicePeer(_ device: VoiceDeviceID) async throws -> VoiceEndpoint {
            guard present, device == endpoint.device else { throw VoiceSignalError.peerUnavailable }
            return endpoint
        }

        func sendVoice(_ payload: VoiceSignalPayload, session: VoiceSessionID, to recipient: VoiceEndpoint) async throws {
            if case .live(.show(_, let sessionID)) = payload {
                switch showing {
                case .sends: revealed.append(sessionID)
                case .fails: throw VoiceSignalError.peerUnavailable
                case .hangs: await withCheckedContinuation { held.append($0) }
                }
                return
            }
            let answer = answer
            func header(_ payload: VoiceSignalPayload, from sender: VoiceEndpoint, to recipient: VoiceEndpoint) -> VoiceSignalHeader {
                VoiceSignalHeader(version: VoiceSignalFormat.version, sender: sender, recipient: recipient, session: session, sequence: 1,
                                  expiresAtMilliseconds: Int64(Date.now.timeIntervalSince1970 * 1000) + 30_000, purpose: payload.purpose)
            }
            if case .live(.back(_, let sessionID)) = payload {
                guard bounces > 0 else { return returned.append(sessionID) }
                bounces -= 1
                let bounced = header(payload, from: local, to: endpoint)
                Task { answer(.rejected(header: bounced, reason: .unavailable)) }
                return
            }
            guard case .live(.watch(let request, let sessionID, let open)) = payload else { return }
            if drops {
                (drops, connected) = (false, false)
                throw VoiceSignalError.peerUnavailable
            }
            opened = open
            let door = open ? door.map { LiveSignal.Door(addresses: $0.addresses, port: $0.port, ticket: ticket) } : nil
            let reply = VoiceSignalPayload.live(signal: .pages(request: request, session: sessionID, pages: pages, serving: found ?? pages, sent: sent, door: door, ports: nil))
            let replied = header(reply, from: endpoint, to: local)
            Task { answer(.received(.init(header: replied, payload: reply))) }
        }
    }

    /// 本进程里的网页服务：什么请求都回同一页，记着载了几次（取 `/` 的请求）；`/stream` 是一条不结束的事件流（热更新那样的长连接）。
    /// 模拟器与 Mac 共用回环，直连也连得上它：所以 Mac 报给手机的是另一个没人听的口，只有隧道那头把它接到这里（`phone`），页面载得出就是走了隧道。
    final class Page {
        let listener: NWListener
        let port: UInt16
        private let loads = OSAllocatedUnfairLock(initialState: 0)
        private let streams = OSAllocatedUnfairLock<[NWConnection]>(initialState: [])
        var loaded: Int { loads.withLock { $0 } }
        var streaming: Int { streams.withLock { $0.count } }

        init(_ body: String) async throws {
            listener = try NWListener(using: .tcp)
            let loads = loads, streams = streams
            listener.newConnectionHandler = { connection in
                connection.start(queue: LiveTunnel.queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, _, _ in
                    let line = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                    if line.hasPrefix("GET /stream ") {
                        streams.withLock { $0.append(connection) }
                        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\n: open\n\n"
                        return connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
                    }
                    if line.hasPrefix("GET / ") { loads.withLock { $0 += 1 } }
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
                    connection.send(content: Data((head + body).utf8), isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            port = try await LivePhoneFlowTests.listen(listener)
        }

        func stop() {
            listener.cancel()
            for connection in streams.withLock({ $0 }) { connection.cancel() }
        }
    }

    final class Network {
        let listener: NWListener
        let port: UInt16
        private let held = OSAllocatedUnfairLock<[NWConnection]>(initialState: [])

        init(to target: UInt16) async throws {
            listener = try NWListener(using: .tcp)
            let held = held
            listener.newConnectionHandler = { inbound in
                let outbound = NWConnection(host: "127.0.0.1", port: .init(rawValue: target)!, using: .tcp)
                held.withLock { $0 += [inbound, outbound] }
                for connection in [inbound, outbound] { connection.start(queue: LiveTunnel.queue) }
                Network.pump(inbound, outbound)
                Network.pump(outbound, inbound)
            }
            port = try await LivePhoneFlowTests.listen(listener)
        }

        private nonisolated static func pump(_ from: NWConnection, _ to: NWConnection) {
            from.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, complete, error in
                if let data, !data.isEmpty { to.send(content: data, completion: .contentProcessed { _ in }) }
                if complete || error != nil { return to.cancel() }
                pump(from, to)
            }
        }

        func cut() { for connection in held.withLock({ let all = $0; $0 = []; return all }) { connection.forceCancel() } }

        func stop() {
            listener.cancel()
            cut()
        }
    }

    nonisolated static func listen(_ listener: NWListener) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { ready in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: ready.resume(returning: listener.port!.rawValue)
                case .failed(let error): ready.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: LiveTunnel.queue)
        }
    }

    func vacant() async throws -> URL {
        let page = try await Page("")
        page.stop()
        return try #require(URL(string: "http://localhost:\(page.port)"))
    }
}
#endif
