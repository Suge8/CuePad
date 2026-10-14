#if os(macOS)
import AppKit
import CueStore
import UserNotifications
import os

/// 通知提示音：App 包里的 4 段（`Sounds/<rawValue>.caf`，合成源是 design/tools/notification-sounds.py）是唯一来源。
nonisolated enum AlertSound: String, CaseIterable, Sendable {
    case chime, tap, bell, drop

    var title: String {
        switch self {
        case .chime: "叮咚"
        case .tap: "轻响"
        case .bell: "风铃"
        case .drop: "水滴"
        }
    }

    var bundled: URL { Bundle.main.url(forResource: rawValue, withExtension: "caf")! }

    /// 装进 ~/Library/Sounds 后的文件名，也是通知用的声音名：带品牌前缀，在系统设置的提示音列表里不撞名。
    var installedName: String { "CuePad \(rawValue.capitalized).caf" }

    /// 直接播包里的文件：设置里试听，与前台提示条那一下（`AlertCenter.present`）。其余提醒的声音经系统通知，遵守专注模式。
    func play() { NSSound(contentsOf: bundled, byReference: true)?.play() }
}

/// 一种提示的偏好。关掉 = 系统横幅、窗口顶上的提示条、声音都没有；`sound` 为 nil 是不出声。
nonisolated struct AlertPreference: Equatable, Sendable {
    var isOn: Bool
    var sound: AlertSound?
}

/// 两种提示（`AlertRoute.kind`：等你、做完了）各自的偏好，本机、不同步（`AppSettings.alerts`）。
nonisolated struct AlertPreferences: Equatable, Sendable {
    var waiting = AlertPreference(isOn: true, sound: .chime)
    var settled = AlertPreference(isOn: true, sound: .drop)

    subscript(kind: PiAlert) -> AlertPreference {
        get { kind == .waitingForUser ? waiting : settled }
        set { if kind == .waitingForUser { waiting = newValue } else { settled = newValue } }
    }

    private static let on = "on", sound = "sound"

    /// 存成 `[种类: [on, sound]]`；没存过的种类用缺省，`sound` 为空串是"无"。
    init(stored: [String: Any]? = nil) {
        for kind in PiAlert.allCases {
            guard let entry = stored?[kind.rawValue] as? [String: Any] else { continue }
            self[kind] = AlertPreference(
                isOn: entry[Self.on] as? Bool ?? self[kind].isOn,
                sound: (entry[Self.sound] as? String).map(AlertSound.init(rawValue:)) ?? self[kind].sound)
        }
    }

    var stored: [String: Any] {
        Dictionary(uniqueKeysWithValues: PiAlert.allCases.map { kind in
            (kind.rawValue, [Self.on: self[kind].isOn, Self.sound: self[kind].sound?.rawValue ?? ""] as [String: Any])
        })
    }
}

/// macOS 的通知中心只在 ~/Library/Sounds 与系统声音目录里找 `UNNotificationSound(named:)`，不看 App 包（包里的声音一律换成系统兜底音）；
/// 一个声音名找不到过一次，之后装上了也播兜底音。所以发带声音的通知前，先把选中的那段从包里复制过去（内容与包里不一致就覆盖），
/// 一次运行每段只核对一次。只在真发通知时用（`AlertCenter.delivers`），隔离库与测试不碰真实的 ~/Library/Sounds。
actor AlertSounds {
    private let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Sounds", directoryHint: .isDirectory)
    private var checked: Set<AlertSound> = []

    func prepare(_ sound: AlertSound) -> UNNotificationSoundName {
        let name = UNNotificationSoundName(sound.installedName)
        guard !checked.contains(sound) else { return name }
        do {
            let source = try Data(contentsOf: sound.bundled)
            let target = directory.appending(path: sound.installedName)
            if (try? Data(contentsOf: target)) != source {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try source.write(to: target, options: .atomic)
            }
            checked.insert(sound)
        } catch {
            Logger(subsystem: AppServices.bundleID, category: "services")
                .error("提示音没能装进 \(self.directory.path, privacy: .public)：\(String(describing: error), privacy: .public)")
        }
        return name
    }
}
#endif
