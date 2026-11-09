#if os(macOS)
import WebKit
import CuePi

extension DebugHooks {
    static func makeVoiceCall(_ dependencies: VoiceCall.Dependencies) -> VoiceCall {
        #if DEBUG
        if DebugScene.args.voiceOpts.layout != nil {
            var dependencies = dependencies
            dependencies.access = {
                let payload = Data(#"{"exp":4102444800,"https://api.openai.com/auth":{"chatgpt_account_id":"isolated-layout"}}"#.utf8).base64EncodedString()
                guard let access = CodexAccess(token: "test.\(payload).test") else { throw CodexAccessError.signedOut }
                return access
            }
            let scenario = DebugVoiceLayoutScenario()
            let tell = dependencies.tell
            dependencies.tell = { text in
                try scenario.beforeRecording()
                return try await tell(text)
            }
            dependencies.media = { _, _ in DebugVoiceLayoutMedia() }
            dependencies.createCall = { _, _, _, _ in .init(id: "layout", answer: "answer", usedPercent: nil) }
            dependencies.control = { _, _, _, received in
                received(.success(.started))
                return DebugVoiceLayoutControl(scenario: scenario)
            }
            return VoiceCall(dependencies)
        }
        #endif
        return VoiceCall(dependencies)
    }

    static func configureVoice(_ web: WKWebView, source: VoicePeer.Source) async throws {
        #if DEBUG
        try await DebugVoice.configure(web, source: source)
        #endif
    }

    static func voiceWire(_ text: String, type: String) {
        #if DEBUG
        if type != "session.input_audio.append", type != "session.output_audio.delta" { DebugVoice.wire(text) }
        #endif
    }
}
#endif
