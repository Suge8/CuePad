#if DEBUG && os(macOS)
import CuePi
import Foundation
import Network

/// Mac 授权只读；每轮的创建、控制、取消由独立 DebugSplitHostCall 拥有。
enum DebugSplitHost {
    static func run() async throws {
        guard let path = DebugScene.defaults.string(forKey: "CuePadSplitAuth"),
              let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(filePath: path))) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any], let token = tokens["access_token"] as? String,
              let access = CodexAccess(token: token), access.expiresAt.timeIntervalSinceNow > 120 else {
            throw DebugSplitVoice.ProbeError.credential
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: DebugSplitVoice.port)
        let listener = try NWListener(using: parameters)
        let accepted = AsyncThrowingStream<NWConnection, Error>.makeStream()
        listener.newConnectionHandler = { accepted.continuation.yield($0) }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { accepted.continuation.finish(throwing: error) }
        }
        listener.start(queue: .main)
        defer { listener.cancel(); accepted.continuation.finish() }
        for try await connection in accepted.stream {
            listener.cancel()
            let pipe = DebugSplitVoice.Pipe(connection)
            pipe.start()
            let host = Host(access: access, pipe: pipe, secrets: [token, access.accountID, tokens["refresh_token"] as? String ?? ""])
            defer { host.close(); pipe.close() }
            // 创建在本轮任务里运行，此循环始终能接收 hangup。
            for try await frame in pipe.frames.stream { try host.receive(frame) }
            return
        }
    }

    private final class Host {
        let access: CodexAccess
        let pipe: DebugSplitVoice.Pipe
        let secrets: [String]
        let scope = DebugSplitScope()
        var current: DebugSplitHostCall?

        init(access: CodexAccess, pipe: DebugSplitVoice.Pipe, secrets: [String]) {
            self.access = access; self.pipe = pipe; self.secrets = secrets.filter { !$0.isEmpty }
        }

        func close() { scope.end(); current?.close(); current = nil }

        func receive(_ frame: DebugSplitVoice.Frame) throws {
            switch frame.kind {
            case "offer":
                guard current == nil, let offer = frame.sdp else { throw DebugSplitVoice.ProbeError.invalid }
                let id = frame.session
                let call = DebugSplitHostCall(id: id, create: { [access] offer in
                    try await VoiceWire.createCall(offer: offer, instructions: "You are an audio transport probe. Do not perform actions.", access: access, session: id)
                }, control: { [access] call, received in
                    VoiceWire.Channel(call: call, access: access, session: id, received: received)
                }, send: { [self] in try await send($0) }, ended: { [weak self] id in self?.finished(id) })
                current = call
                call.scope.spawn {
                    do { try await Task.sleep(for: .seconds(100)); call.close() }
                    catch { }
                }
                call.begin(offer: offer)
            case "connected": if current?.id == frame.session { current?.connected() }
            case "hangup": if current?.id == frame.session { current?.close() }
            default: throw DebugSplitVoice.ProbeError.invalid
            }
        }

        func finished(_ id: UUID) {
            // 这里只摘除路由槽位；旧会话没有取得新会话资源的入口。
            if current?.id == id { current = nil }
            scope.spawn {
                do { try await self.send(.init(kind: "closed", session: id)) }
                catch { DebugSplitVoice.note("close-ack-unconfirmed") }
            }
        }

        func send(_ frame: DebugSplitVoice.Frame) async throws {
            let data = try JSONEncoder().encode(frame)
            guard !secrets.contains(where: String(decoding: data, as: UTF8.self).contains) else { throw DebugSplitVoice.ProbeError.credential }
            DebugSplitVoice.note("outbound kind=\(frame.kind) credentialMatch=false bytes=\(data.count)")
            try await pipe.send(frame)
        }
    }
}
#endif
