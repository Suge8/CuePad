#if os(iOS) && DEBUG
import Foundation

/// -CuePadPhoneVoiceReplay interactive|normal|rapid：只替换远端投影与媒体，静音、关闭仍走正式 VoiceService。
/// 配合 -CuePadPhoneVoice listening 和隔离库；没有信令或真实音频，不用于发起、跨设备与音画同步验收。
/// cycle（配 -CuePadPhoneVoice idle）：录输入框与通话条的来回——空着→接通→听、回应、静音→正常挂断→再接通→音频中断→打字让通话换成发送、删掉换回来。
/// 接通照 `VoiceService.start` 摆出的样子换上新的媒体所有者与投影（没有信令），挂断与中断走正式的 `end`。
enum DebugPhoneVoiceReplay {
    /// 在写投影之前换上媒体所有者（同正式的 start）：所有者不在观察里，先写投影的话读能否静音的视图不会按它重算。
    static func attach(_ voice: VoiceService, workspace: Workspace, session: VoiceSessionID) {
        guard let mode = DebugScene.defaults.string(forKey: "CuePadPhoneVoiceReplay") else { return }
        if mode == "cycle" {
            Task {
                do { try await cycle(voice, workspace: workspace) }
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

    private static func cycle(_ voice: VoiceService, workspace: Workspace) async throws {
        let local = VoiceEndpoint(device: VoiceDeviceID("voice-ui-replay"), lease: UUID())
        func show(_ phase: VoiceCallProjection.Phase, response: VoiceCallProjection.Response = .none) {
            guard let session = voice.session else { return }
            voice.setProjection(.init(session: session, phase: phase, requests: [], replies: [], executions: [], response: response))
        }
        func connect() async throws {
            let owner = VoicePhoneSession(id: VoiceSessionID(UUID()), local: local, media: Media())
            voice.phone = owner
            voice.phoneEnd = nil
            voice.session = owner.id
            voice.setProjection(nil)
            try await Task.sleep(for: .milliseconds(900))
            owner.connected = true
            show(.listening)
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

    private static func samples(_ voice: VoiceService, count: Int) async throws {
        for index in 0..<count {
            let peak = 0.12 + 0.65 * abs(sin(Double(index) * 0.47))
            voice.inputSamples = Array((voice.inputSamples + [peak]).suffix(VoicePeer.sampleCount))
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private final class Media: VoiceMedia {
        var onEvent: (VoicePeer.Event) -> Void = { _ in }
        func offer() async throws -> String { throw VoiceSignalError.unsupported }
        func accept(answer: String) async throws { throw VoiceSignalError.unsupported }
        func play() async throws { }
        func setMuted(_ muted: Bool) async throws { }
        func close() async throws {
            try await Task.sleep(for: .milliseconds(500))
            FileHandle.standardError.write(Data("phone-voice-replay media-closed\n".utf8))
        }
    }
}
#endif
