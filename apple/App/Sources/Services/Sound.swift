import AudioToolbox
import CueStore

/// 全 App 的声音只有这几段（`Sounds/<名字>.caf`，来源与响度见 `design/tools/sounds.py`）。哪件事配哪一声写在出声的地方，不给用户挑；
/// 开关只有设置里那一个（`AppSettings.sounds`），所以出声都经 `AppSettings.play`。
/// 只报个结果的提示（已复制、已记下）不出声：一天上百次，响了是打扰。
nonisolated enum Sound: String, Sendable {
    /// 通知的两声（`AlertTone`），手机前台的会话提示也用。
    case ask, done
    /// 一句话交给了 Agent 或 Cue。
    case send
    /// 做完一件任务。
    case check
    /// 做了一件能撤的事（归档、删除、合并）。
    case act
    case undo
    case fail
    /// 拖着的任务落了位。
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
