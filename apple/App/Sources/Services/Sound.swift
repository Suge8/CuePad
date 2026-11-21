import AudioToolbox
import CueStore

nonisolated enum Sound: String, Sendable {
    case ask, done
    case send
    case check
    case act
    case undo
    case fail
    case drop

    init(_ tone: AlertTone) {
        switch tone {
        case .ask: self = .ask
        case .done: self = .done
        }
    }

    var bundled: URL { Bundle.main.url(forResource: rawValue, withExtension: "caf")! }

    @MainActor private static var loaded: [Sound: SystemSoundID] = [:]

    /// 走系统的界面音：Mac 听"声音 › 播放用户界面声音效果"与提示音量，手机与 iPad 听静音键。
    @MainActor fileprivate func play() {
        if Self.loaded[self] == nil {
            var id: SystemSoundID = 0
            AudioServicesCreateSystemSoundID(bundled as CFURL, &id)
            Self.loaded[self] = id
        }
        if let id = Self.loaded[self] { AudioServicesPlaySystemSound(id) }
    }
}

extension AppSettings {
    func play(_ sound: Sound) {
        if sounds { sound.play() }
    }
}
