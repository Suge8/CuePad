#if os(iOS) && DEBUG
import Foundation

/// -CuePadPhoneVoiceReplay interactive|normal|rapid：只替换远端投影与媒体，静音、关闭仍走正式 VoiceService。
/// 配合 -CuePadPhoneVoice listening 和隔离库；没有信令或真实音频，不用于发起、跨设备与音画同步验收。
enum DebugPhoneVoiceReplay {
    static func attach(_ voice: VoiceService) {
        guard let mode = DebugScene.args.phoneVoiceOpts.replay, let initial = voice.projection else { return }
        let local = VoiceEndpoint(device: VoiceDeviceID("voice-ui-replay"), lease: UUID())
        let owner = VoicePhoneSession(id: initial.session, local: local, media: Media())
        owner.connected = true
        voice.phone = owner
        voice.session = initial.session
        guard mode != "interactive" else { return }
        owner.scope.spawn {
            do { try await run(mode, voice: voice, owner: owner, initial: initial) }
            catch is CancellationError { }
            catch { DebugScene.abandon("手机通话隔离回放", error) }
        }
    }

    private static func run(_ mode: String, voice: VoiceService, owner: VoicePhoneSession, initial: VoiceCallProjection) async throws {
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
