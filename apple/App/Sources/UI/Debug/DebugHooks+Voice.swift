#if os(macOS)
import CueBridge
import Foundation

extension DebugHooks {
    static func makeVoiceCall(_ dependencies: VoiceCall.Dependencies, record: VoiceRecord) -> VoiceCall {
        #if DEBUG
        if DebugScene.args.voiceOpts.layout != nil {
            var dependencies = dependencies
            dependencies.access = {
                let payload = Data(#"{"exp":4102444800,"https://api.openai.com/auth":{"chatgpt_account_id":"isolated-layout"}}"#.utf8).base64EncodedString()
                guard let access = CodexAccess(token: "test.\(payload).test") else { throw CodexAccessError.signedOut }
                return access
            }
            let scenario = DebugVoiceLayoutScenario()
            let tell = record.tell
            record.tell = { text, command in
                try scenario.beforeRecording()
                return try await tell(text, command)
            }
            dependencies.media = { _ in DebugVoiceLayoutMedia() }
            dependencies.createCall = { _, _, _, _, _ in .init(id: "layout", answer: "answer", usedPercent: nil) }
            dependencies.control = { _, _, _, received in
                received(.success(.started))
                return DebugVoiceLayoutControl(scenario: scenario)
            }
            return VoiceCall(dependencies, record: record)
        }
        #endif
        return VoiceCall(dependencies, record: record)
    }

    static func voiceWire(_ text: String) {
        #if DEBUG
        DebugVoiceLog.wire(text)
        #endif
    }

    static func voiceProjectionSend() throws {
        #if DEBUG
        if let until = DebugScene.projectionFailsUntil, ContinuousClock.now < until { throw URLError(.timedOut) }
        #endif
    }
}
#endif
