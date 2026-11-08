#if DEBUG && os(macOS)
import Foundation

/// 审计临时复现：无授权、无网络、不作为项目正式测试保留。
enum DebugSplitAudit {
    static func run() async throws {
        for label in ["permission", "javascript", "send"] { try await cancelledWait(label) }
        try await creatingHangup()
        try await lateControlFailure()
        try wireFixture()
        DebugSplitVoice.note("audit-complete")
    }

    private static func require(_ condition: Bool) throws {
        if !condition { throw DebugSplitVoice.ProbeError.invalid }
    }

    private static func cancelledWait(_ label: String) async throws {
        let scope = DebugSplitScope()
        let gate = Gate<Bool>()
        let task = Task {
            do { _ = try await scope.wait { gate.callback = $0; gate.started.continuation.yield() }; return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        await gate.entered()
        scope.end()
        try require(await task.value)
        gate.callback?(.success(true))
        DebugSplitVoice.note("audit-\(label)-cancelled-before-callback")
    }

    private static func creatingHangup() async throws {
        let gate = Gate<VoiceWire.Call>()
        var sent = 0, closed = 0
        let old = DebugSplitHostCall(id: UUID(), create: { _ in try await gate.wait() }, control: { _, _ in Control() },
                                     send: { _ in sent += 1 }, ended: { _ in closed += 1 })
        let creating = old.begin(offer: "probe")
        await gate.entered()
        old.close()
        try require(closed == 1)
        gate.callback?(.success(.init(id: "old", answer: "answer", usedPercent: nil)))
        await creating?.value
        try require(sent == 0)
        DebugSplitVoice.note("audit-hangup-during-create no-late-answer=true")
    }

    private static func lateControlFailure() async throws {
        let gate = Gate<Void>()
        let oldControl = Control(gate: gate), newControl = Control()
        var callback: ((Result<VoiceWire.Event, VoiceWire.SidebandClosed>) -> Void)?
        let old = DebugSplitHostCall(id: UUID(), create: { _ in .init(id: "old", answer: "answer", usedPercent: nil) },
                                     control: { _, received in callback = received; return oldControl }, send: { _ in }, ended: { _ in })
        await old.begin(offer: "probe")?.value
        old.connected()
        callback?(.success(.started))
        await gate.entered()
        let pending = old.close()
        let new = DebugSplitHostCall(id: UUID(), create: { _ in .init(id: "new", answer: "answer", usedPercent: nil) },
                                     control: { _, _ in newControl }, send: { _ in }, ended: { _ in })
        await new.begin(offer: "probe")?.value
        new.connected()
        gate.callback?(.failure(DebugSplitVoice.ProbeError.invalid))
        for task in pending { await task.value }
        try require(oldControl.closed == 1 && newControl.closed == 0 && !new.scope.ended)
        new.close()
        DebugSplitVoice.note("audit-late-send-error new-call-untouched=true")
    }

    private final class Gate<Value: Sendable> {
        let started = AsyncStream<Void>.makeStream()
        var callback: ((Result<Value, Error>) -> Void)?
        func entered() async { for await _ in started.stream { return } }
        func wait() async throws -> Value {
            try await withCheckedThrowingContinuation { continuation in
                callback = { continuation.resume(with: $0) }
                started.continuation.yield()
            }
        }
    }

    private final class Control: VoiceControl {
        let gate: Gate<Void>?
        var closed = 0
        init(gate: Gate<Void>? = nil) { self.gate = gate }
        func send(_ outgoing: VoiceWire.Outgoing) async throws { try await gate?.wait() }
        func close() { closed += 1 }
    }
}
#endif
