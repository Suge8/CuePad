#if os(macOS)
import Foundation

extension Workspace {
    func toggleVoiceCall(source: VoicePeer.Source = .microphone) {
        if let voice, voice.isLive { return voice.hangUp() }
        startVoiceCall(source: source)
    }

    func startVoiceCall(source: VoicePeer.Source = .microphone) {
        showCue()
        guard voice?.isLive != true else { return }
        if let block = voiceStartBlock { return say(block.message, tone: .failure) }
        services.voice.startLocal(source: source)
    }
}
#endif
