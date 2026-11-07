#if os(macOS)
import WebKit

extension DebugHooks {
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
