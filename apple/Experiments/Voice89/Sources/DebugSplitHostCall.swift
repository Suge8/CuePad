#if DEBUG && os(macOS)
import Foundation

/// 控制回调与创建任务捕获本轮 owner；错误只能关闭本轮 channel，不能访问下一轮或关闭共享 Pipe。
final class DebugSplitHostCall {
    let id: UUID
    let scope = DebugSplitScope()
    private var call: VoiceWire.Call?
    private var channel: (any VoiceControl)?
    private let create: (String) async throws -> VoiceWire.Call
    private let control: (String, @escaping (Result<VoiceWire.Event, VoiceWire.SidebandClosed>) -> Void) -> any VoiceControl
    private let send: (DebugSplitVoice.Frame) async throws -> Void
    private let ended: (UUID) -> Void

    init(
        id: UUID, create: @escaping (String) async throws -> VoiceWire.Call,
        control: @escaping (String, @escaping (Result<VoiceWire.Event, VoiceWire.SidebandClosed>) -> Void) -> any VoiceControl,
        send: @escaping (DebugSplitVoice.Frame) async throws -> Void, ended: @escaping (UUID) -> Void
    ) {
        self.id = id; self.create = create; self.control = control; self.send = send; self.ended = ended
    }

    @discardableResult func begin(offer: String) -> Task<Void, Never>? {
        scope.spawn { [self] in
            do {
                let prepared = try await create(offer)
                try Task.checkCancellation()
                call = prepared
                try await send(.init(kind: "answer", session: id, sdp: prepared.answer))
            } catch { close() }
        }
    }

    func connected() {
        guard !scope.ended, let call, channel == nil else { return }
        channel = control(call.id) { [weak self] event in
            guard let self else { return }
            self.scope.spawn {
                do { try await self.receive(event) }
                catch { self.close() }
            }
        }
    }

    @discardableResult func close() -> [Task<Void, Never>] {
        guard !scope.ended else { return [] }
        let tasks = scope.end()
        channel?.close(); channel = nil; call = nil
        ended(id)
        return tasks
    }

    private func receive(_ result: Result<VoiceWire.Event, VoiceWire.SidebandClosed>) async throws {
        switch result {
        case .success(.started):
            guard let channel else { throw DebugSplitVoice.ProbeError.ended }
            try await channel.send(.say("连接验证完成。"))
            DebugSplitVoice.note("control-sent session=\(id)")
        case .success(.context): try await send(.init(kind: "context", session: id))
        case .success(.error), .failure: close()
        default: break
        }
    }
}
#endif
