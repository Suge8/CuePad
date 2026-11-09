#if os(iOS) && DEBUG
import Foundation

/// -CuePadPhoneVoiceReplay interactive|normal|rapid：只替换远端投影与媒体，静音、关闭仍走正式 VoiceService。
/// 配合 -CuePadPhoneVoice listening 和隔离库；没有信令或真实音频，不用于发起、跨设备与音画同步验收。
/// cycle（配 -CuePadPhoneVoice idle）：录输入框与通话条的来回——空着→接通→听、回应、静音→正常挂断→再接通→音频中断→打字让通话换成发送、删掉换回来。
/// reverse（配 -CuePadPhoneVoice idle）：快速反向——接通动画走到一半就挂断、挂断动画走到一半又接通、打一个字马上删掉，看过渡从当前样子接着走、不闪。
/// 接通照 `VoiceService.start` 摆出的样子换上新的媒体所有者与投影（没有信令），挂断与中断走正式的 `end`。
enum DebugPhoneVoiceReplay {
    /// 在写投影之前换上媒体所有者（同正式的 start）：所有者不在观察里，先写投影的话读能否静音的视图不会按它重算。
    static func attach(_ voice: VoiceService, workspace: Workspace, session: VoiceSessionID) {
        guard let mode = DebugScene.args.phoneVoiceOpts.replay else { return }
        if mode == "cycle" || mode == "reverse" {
            Task {
                do { try await mode == "cycle" ? cycle(voice, workspace: workspace) : reverse(voice, workspace: workspace) }
                catch { DebugScene.abandon("手机通话隔离回放", error) }
            }
            return
        }
        let local = VoiceEndpoint(device: VoiceDeviceID("voice-ui-replay"), lease: UUID())
        let owner = VoicePhoneSession(id: session, local: local, media: Media())
        owner.connected = true
        voice.phone = owner
        voice.session = session
        guard mode != "interactive" else { return }
        owner.scope.spawn {
            do { try await run(mode, voice: voice, owner: owner) }
            catch is CancellationError { }
            catch { DebugScene.abandon("手机通话隔离回放", error) }
        }
    }

    private static func run(_ mode: String, voice: VoiceService, owner: VoicePhoneSession) async throws {
        guard let initial = voice.projection else { return }
        @MainActor func show(_ phase: VoiceCallProjection.Phase, response: VoiceCallProjection.Response = .none) {
            voice.setProjection(.init(session: initial.session, phase: phase, requests: initial.requests,
                                      replies: initial.replies, executions: initial.executions, response: response,
                                      omitted: initial.omitted, pages: initial.pages, canRepeat: false))
        }
        try await Task.sleep(for: .seconds(2))
        owner.connected = false
        show(.connecting)
        try await Task.sleep(for: .milliseconds(700))
        owner.connected = true
        show(.listening)
        try await samples(voice, count: 30)
        show(.listening, response: .awaitingAssistant)
        try await Task.sleep(for: .milliseconds(850))
        show(.listening, response: .assistantTurn)
        try await samples(voice, count: 35)
        show(.listening)
        if mode == "rapid" {
            for index in 0..<12 {
                show(.listening, response: index.isMultiple(of: 2) ? .assistantTurn : .none)
                FileHandle.standardError.write(Data("phone-voice-replay reverse-\(index)\n".utf8))
                try await Task.sleep(for: .milliseconds(90))
            }
        }
        try await voice.setMuted(true)
        try await Task.sleep(for: .seconds(1))
        try await voice.setMuted(false)
        try await samples(voice, count: 20)
        FileHandle.standardError.write(Data("phone-voice-replay ready-for-interaction\n".utf8))
    }

    /// 拨出：同 `start` 摆出的"正在连接"（换上媒体所有者与会话，投影清空）。
    @discardableResult
    static func dial(_ voice: VoiceService) -> VoicePhoneSession {
        let owner = VoicePhoneSession(id: VoiceSessionID(UUID()), local: VoiceEndpoint(device: VoiceDeviceID("voice-ui-replay"), lease: UUID()), media: Media())
        voice.phone = owner
        voice.phoneEnd = nil
        voice.session = owner.id
        voice.setProjection(nil)
        return owner
    }

    /// 接通：媒体连上、投影到"在听"。
    static func answer(_ voice: VoiceService) {
        voice.phone?.connected = true
        show(voice, .listening)
    }

    static func show(_ voice: VoiceService, _ phase: VoiceCallProjection.Phase, response: VoiceCallProjection.Response = .none) {
        guard let session = voice.session else { return }
        voice.setProjection(.init(session: session, phase: phase, requests: [], replies: [], executions: [], response: response))
    }

    private static func cycle(_ voice: VoiceService, workspace: Workspace) async throws {
        func show(_ phase: VoiceCallProjection.Phase, response: VoiceCallProjection.Response = .none) { Self.show(voice, phase, response: response) }
        func connect() async throws {
            dial(voice)
            try await Task.sleep(for: .milliseconds(900))
            answer(voice)
        }
        try await Task.sleep(for: .seconds(2))
        try await connect()
        try await samples(voice, count: 30)
        show(.listening, response: .awaitingAssistant)
        try await Task.sleep(for: .milliseconds(800))
        show(.listening, response: .assistantTurn)
        try await samples(voice, count: 34)
        show(.listening)
        try await voice.setMuted(true)
        try await Task.sleep(for: .milliseconds(1200))
        try await voice.setMuted(false)
        try await samples(voice, count: 20)
        await voice.end()
        try await Task.sleep(for: .seconds(2))
        try await connect()
        try await samples(voice, count: 30)
        await voice.end(reason: .audioInterrupted, notify: false)
        try await Task.sleep(for: .seconds(3))
        for character in String(localized: "帮我看看发布", table: "Demo") {
            workspace.cue.draft.text.append(character)
            try await Task.sleep(for: .milliseconds(160))
        }
        try await Task.sleep(for: .milliseconds(1500))
        workspace.cue.draft.text = ""
        FileHandle.standardError.write(Data("phone-voice-replay cycle-done\n".utf8))
    }

    /// 每一步都落在上一段过渡（0.16～0.25 秒）的半途。挂断要等媒体关完（替身 0.5 秒）才回到空着，这一段里再拨不了，同真的。
    private static func reverse(_ voice: VoiceService, workspace: Workspace) async throws {
        func mark(_ step: String) { FileHandle.standardError.write(Data("phone-voice-replay \(step)\n".utf8)) }
        try await Task.sleep(for: .seconds(2))
        for round in 0..<3 {
            mark("dial-\(round)")
            dial(voice)
            try await Task.sleep(for: .milliseconds(round == 0 ? 90 : 400))
            if round > 0 {
                answer(voice)
                try await samples(voice, count: 3)
            }
            mark("hang-\(round)")
            await voice.end()
            // 回到空着后 80ms 又拨：输入框正从通话条变回来
            try await Task.sleep(for: .milliseconds(80))
        }
        try await Task.sleep(for: .milliseconds(900))
        for _ in 0..<3 {
            mark("type")
            workspace.cue.draft.text = String(localized: "帮我看看发布", table: "Demo")
            try await Task.sleep(for: .milliseconds(90))
            workspace.cue.draft.text = ""
            try await Task.sleep(for: .milliseconds(90))
        }
        try await Task.sleep(for: .milliseconds(600))
        mark("dial-last")
        dial(voice)
        try await Task.sleep(for: .milliseconds(300))
        answer(voice)
        try await samples(voice, count: 16)
        try await voice.setMuted(true)
        try await Task.sleep(for: .milliseconds(120))
        try await voice.setMuted(false)
        try await samples(voice, count: 10)
        mark("hang-last")
        await voice.end()
        mark("reverse-done")
    }

    private static func samples(_ voice: VoiceService, count: Int) async throws {
        for index in 0..<count {
            let peak = 0.12 + 0.65 * abs(sin(Double(index) * 0.47))
            voice.inputSamples = Array((voice.inputSamples + [peak]).suffix(VoicePeer.sampleCount))
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    final class Media: VoiceMedia {
        var onEvent: (VoicePeer.Event) -> Void = { _ in }
        func offer() async throws -> String { throw VoiceSignalError.unsupported }
        func accept(answer: String) async throws { throw VoiceSignalError.unsupported }
        func setMuted(_ muted: Bool) async throws { }
        func close() async {
            await Task.wait(for: .milliseconds(500))
            FileHandle.standardError.write(Data("phone-voice-replay media-closed\n".utf8))
        }
    }
}
#endif
