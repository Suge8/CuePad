import AVFoundation
import CueStore
import Observation
import os

@Observable final class VoicePreview: NSObject, AVAudioPlayerDelegate {
    private(set) var playing: CueVoice?
    @ObservationIgnored private var player: AVAudioPlayer?

    func play(_ voice: CueVoice) throws {
        stop()
        let player = try AVAudioPlayer(contentsOf: Self.sample(voice))
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        player.delegate = self
        player.play()
        self.player = player
        playing = voice
    }

    func stop() {
        player?.stop()
        finished()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in if let player = self.player, ObjectIdentifier(player) == id { self.finished() } }
    }

    private func finished() {
        guard player != nil else { return }
        player = nil
        playing = nil
        #if os(iOS)
        do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        catch { Logger(subsystem: AppIdentity.id, category: "voice").error("Preview audio session not deactivated: \(error.localizedDescription, privacy: .public)") }
        #endif
    }

    private static func sample(_ voice: CueVoice) -> URL {
        let language = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? "zh" : "en"
        return Bundle.main.url(forResource: "\(voice.rawValue)-\(language)", withExtension: "m4a")!
    }
}
