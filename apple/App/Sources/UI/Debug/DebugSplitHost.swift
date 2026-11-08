#if DEBUG && os(macOS)
import CuePi
import Foundation
import Network

/// Mac 持有唯一控制连接；手机拿到的只有本次 answer。授权文件只读一次，过期直接失败，不走 app-server。
enum DebugSplitHost {
    static func run() async throws {
        guard let path = DebugScene.defaults.string(forKey: "CuePadSplitAuth"),
              let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(filePath: path))) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any], let token = tokens["access_token"] as? String,
              let access = CodexAccess(token: token), access.expiresAt.timeIntervalSinceNow > 120 else {
            throw DebugSplitVoice.ProbeError.credential
        }
        DebugSplitVoice.note("auth-read-only valid=true pid=\(getpid())")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: DebugSplitVoice.port)
        let listener = try NWListener(using: parameters)
        let accepted = AsyncThrowingStream<NWConnection, Error>.makeStream()
        listener.newConnectionHandler = { accepted.continuation.yield($0) }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: Task { @MainActor in DebugSplitVoice.note("listener-ready loopback-only=true") }
            case .failed(let error): accepted.continuation.finish(throwing: error)
            default: break
            }
        }
        listener.start(queue: .main)
        defer { listener.cancel(); accepted.continuation.finish() }
        for try await connection in accepted.stream {
            listener.cancel()
            let pipe = DebugSplitVoice.Pipe(connection)
            pipe.start()
            let host = CallHost(access: access, pipe: pipe, secrets: [token, access.accountID, tokens["refresh_token"] as? String ?? ""])
            defer { host.channel?.close(); pipe.close() }
            for try await frame in pipe.frames.stream { try await host.receive(frame) }
            return
        }
    }

    private final class CallHost {
        let access: CodexAccess
        let pipe: DebugSplitVoice.Pipe
        let secrets: [String]
        var session: UUID?
        var previous: UUID?
        var call: VoiceWire.Call?
        var channel: VoiceWire.Channel?

        init(access: CodexAccess, pipe: DebugSplitVoice.Pipe, secrets: [String]) {
            self.access = access
            self.pipe = pipe
            self.secrets = secrets.filter { !$0.isEmpty }
        }

        func receive(_ frame: DebugSplitVoice.Frame) async throws {
            switch frame.kind {
            case "offer":
                guard session == nil, let offer = frame.sdp else { throw DebugSplitVoice.ProbeError.invalid }
                session = frame.session
                DebugSplitVoice.note("offer bytes=\(offer.utf8.count) session=\(frame.session)")
                do {
                    call = try await VoiceWire.createCall(
                        offer: offer, instructions: "You are an audio transport probe. Speak the supplied speakable text briefly. Do not perform actions.",
                        access: access, session: frame.session)
                } catch let error as VoiceWire.Failure {
                    switch error {
                    case .signedOut: DebugSplitVoice.note("create-http=401")
                    case .notAllowed(let status), .server(let status, _): DebugSplitVoice.note("create-http=\(status)")
                    case .malformed: DebugSplitVoice.note("create-malformed")
                    }
                    throw error
                }
                guard let call else { throw DebugSplitVoice.ProbeError.invalid }
                DebugSplitVoice.note("created answerBytes=\(call.answer.utf8.count)")
                if let previous { try await send(.init(kind: "context", session: previous, detail: "injected-old-call")) }
                try await send(.init(kind: "answer", session: frame.session, sdp: call.answer))
            case "connected":
                guard session == frame.session, let call, channel == nil else { throw DebugSplitVoice.ProbeError.invalid }
                let id = frame.session
                channel = VoiceWire.Channel(call: call.id, access: access, session: id) { [weak self] event in
                    Task { @MainActor in
                        guard let self, self.session == id else { DebugSplitVoice.note("old-control-event-dropped"); return }
                        do { try await self.receive(event, session: id) }
                        catch { DebugSplitVoice.note("control-send-failed"); self.channel?.close(); self.pipe.close() }
                    }
                }
            case "hangup":
                guard session == frame.session else { DebugSplitVoice.note("old-hangup-dropped"); return }
                channel?.close(); channel = nil; call = nil
                previous = session; session = nil
                DebugSplitVoice.note("control-closed session=\(frame.session)")
                try await send(.init(kind: "closed", session: frame.session))
            default: throw DebugSplitVoice.ProbeError.invalid
            }
        }

        func receive(_ event: Result<VoiceWire.Event, VoiceWire.SidebandClosed>, session: UUID) async throws {
            switch event {
            case .success(.started):
                DebugSplitVoice.note("sideband-started session=\(session)")
                try await channel?.send(.say("连接验证完成。"))
                DebugSplitVoice.note("control-sent")
            case .success(.context):
                DebugSplitVoice.note("context-accepted session=\(session)")
                try await send(.init(kind: "context", session: session))
            case .success(.turn(_, let assistant, let done, _)):
                if done { DebugSplitVoice.note("turn-done assistant=\(assistant)") }
            case .success(.usage(let ms)): DebugSplitVoice.note("audioMs=\(ms)")
            case .success(.error): DebugSplitVoice.note("server-error"); pipe.close()
            case .failure(let error): DebugSplitVoice.note("sideband-failed status=\(error.status ?? 0)"); pipe.close()
            default: break
            }
        }

        func send(_ frame: DebugSplitVoice.Frame) async throws {
            let data = try JSONEncoder().encode(frame)
            let text = String(decoding: data, as: UTF8.self)
            guard !secrets.contains(where: text.contains) else { throw DebugSplitVoice.ProbeError.credential }
            DebugSplitVoice.note("outbound kind=\(frame.kind) credentialMatch=false bytes=\(data.count)")
            try await pipe.send(frame)
        }
    }
}
#endif
