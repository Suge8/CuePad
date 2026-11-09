#if os(macOS) && DEBUG
import CuePi
import CueStore
import Foundation

/// -CuePadVoiceScenario recovery|partial|stop：失败只注入外部边界，恢复、结果来源与停止权限仍由正式通话和库判断。
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
        for await ready in Observations({ call.requests.first.map { !$0.isRecording } == true }) where ready { break }
        if kind == "recovery" { return }
        guard let request = call.requests.first?.message else { throw CueStoreError.notFound }
        try await store.markCueMessagesDelivered([request])
        if kind == "stop" {
            try await seedExecution(store, request: request)
            for await ready in Observations({ workspace.voicePresentation?.canStopExecution == true }) where ready { break }
        } else if kind == "partial" {
            let paragraph = String(localized: "**演示结果 \(1)**\n\n- 核对 Mac 界面\n- 核实手机接入", table: "Demo")
            let result = String(repeating: paragraph + "\n\n", count: Self.partialParagraphs)
            _ = try await store.addCueMessage(.cue, text: result, answeredRequests: [request])
            for await ended in Observations({ !call.isLive }) where ended { break }
        }
    }

    /// 执行器替代远端 Agent；种子包含真实的请求→工具→投送→当前用户消息归属链。
    private static func seedExecution(_ store: CueStore, request: UUID) async throws {
        let host = "demo-mac", session = "voice-layout-owned"
        try await DebugScene.keepDemoPresence(store)
        let recorder = DebugScene.demoRecorder(store, host: host)
        let title = String(localized: "检查发布事项 \(1)", table: "Demo")
        try await recorder.update(sessionID: session, state: .thinking, title: title, directory: "demo", projectID: Project.defaultID)
        guard let target = try await store.piSessions(sessionIDs: [session])[session]?.state else { throw CueStoreError.notFound }
        let delivery = try await store.requestDelivery(title, to: target.target, on: host)
        var tool = PiChatMessage.Tools.Item(kind: .command, target: title)
        tool.cueRequests = [request]
        tool.deliveries = [delivery.id]
        _ = try await store.recordCueRound(nil, startedAt: .now, answersYou: true, tools: .init(steps: 1, items: [tool]))
        try await store.writePiTranscript(PiTranscript(sessionID: session, messages: [
            PiChatMessage(sessionID: session, entryID: "owned", seq: 1, role: .user, text: title, at: .now, deliveryID: delivery.id)
        ], recap: PiRecap(lastPrompt: title)))
        let executor = DeliveryExecutor(store: store, hostID: host, onIssue: { error in
            Task { @MainActor in DebugScene.abandon("语音停止验收", error) }
        }) { item, _ in
            if item.mode == .known(.stopTurn) {
                guard item.content == delivery.id.uuidString, item.target == target.target else {
                    return .failed(.verbatim("Unexpected stop identity"))
                }
                do { try await recorder.update(sessionID: session, state: .settled) }
                catch { return .failed(ShownText(error)) }
                FileHandle.standardError.write(Data("voice-layout-stop \(item.content)\n".utf8))
            }
            return .succeeded
        }
        try await executor.start()
    }
}
#endif
