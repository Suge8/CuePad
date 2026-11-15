#if os(macOS) && DEBUG
import CueStore
import Foundation

/// -CuePadVoiceScenario recovery|partial：失败只注入外部边界，恢复与结果来源仍由正式通话和库判断。
/// partial 只失败第一次传输的首片；其后连接不补发，只有实际按重说才会再次提交。
final class DebugVoiceLayoutScenario {
    private let kind = DebugScene.args.voiceOpts.scenario
    private var recorded = false
    private var sent = false
    /// 跨过真实控制通道的分片上限，首片失败必须留下未发送的后续片。
    private static let partialParagraphs = 40

    func beforeRecording() throws {
        defer { recorded = true }
        if kind == "recovery", !recorded { throw CocoaError(.fileWriteNoPermission) }
    }

    func send(_ outgoing: VoiceWire.Outgoing) throws {
        let partial = kind == "partial" && !sent
        sent = true
        let messages = partial ? Array(outgoing.messages.prefix(1)) : outgoing.messages
        for message in messages {
            let data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
            FileHandle.standardError.write(Data("voice-layout-send ".utf8) + data + Data("\n".utf8))
        }
        if partial { throw URLError(.networkConnectionLost) }
    }

    static func seed(_ call: VoiceCall, workspace: Workspace) async throws {
        guard let kind = DebugScene.args.voiceOpts.scenario else { return }
        let store = workspace.services.store
        let text = String(localized: "检查发布事项 \(1)", table: "Demo")
        call.inputs.continuation.yield(.wire(.success(.delegation(.init(id: "layout-request", turn: nil, text: text)))))
        for await ready in Observations({ call.record.requests.first.map { !$0.isRecording } == true }) where ready { break }
        if kind == "recovery" { return }
        guard let request = call.record.requests.first?.message else { throw CueStoreError.notFound }
        try await store.markCueMessagesDelivered([request])
        if kind == "partial" {
            let paragraph = String(localized: "**演示结果 \(1)**\n\n- 核对 Mac 界面\n- 核实手机接入", table: "Demo")
            let result = String(repeating: paragraph + "\n\n", count: Self.partialParagraphs)
            _ = try await store.addCueMessage(.cue, text: result, answeredRequests: [request])
            for await ended in Observations({ !call.isLive }) where ended { break }
        }
    }
}
#endif
