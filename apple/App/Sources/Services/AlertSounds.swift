#if os(macOS)
import CryptoKit
import CueStore
import UserNotifications
import os

/// 每种提示开没开：关掉 = 系统横幅与声音都没有。本机、不同步。
nonisolated struct AlertPreferences: Equatable, Sendable {
    private var off: Set<AlertKind>

    subscript(kind: AlertKind) -> Bool {
        get { !off.contains(kind) }
        set { if newValue { off.remove(kind) } else { off.insert(kind) } }
    }

    private static let on = "on"

    /// 存成 `[种类: [on: 开没开]]`（里面那层是每种提示还能各挑一段提示音时的形状，留着是为了读得出那时关掉的）；没存过的开着。
    init(stored: [String: Any]? = nil) {
        off = Set(AlertKind.allCases.filter { (stored?[$0.rawValue] as? [String: Any])?[Self.on] as? Bool == false })
    }

    var stored: [String: Any] {
        Dictionary(uniqueKeysWithValues: AlertKind.allCases.map { ($0.rawValue, [Self.on: self[$0]]) })
    }
}

/// macOS 的通知中心只在 ~/Library/Sounds 与系统声音目录里找 `UNNotificationSound(named:)`，不看 App 包（包里的声音一律换成系统兜底音）；
/// 一个声音名找不到过一次，之后装上了也播兜底音。所以发带声音的通知前，先把那一段从包里复制过去（内容与包里不一致就覆盖），
/// 一次运行每段只核对一次。只在真发通知时用（`AlertCenter.delivers`），隔离库与测试不碰真实的 ~/Library/Sounds。
actor AlertSounds {
    private let directory = UserHome.directory.appending(path: "Library/Sounds", directoryHint: .isDirectory)
    private var checked: Set<Sound> = []
    /// 能各挑一段提示音时装过的四段（名字与内容的 SHA-256；那四段只发过这一版）：留着会一直挂在系统设置的提示音列表里。
    /// 内容对不上的是用户自己放的同名文件，不动。
    private static let retired = [
        "Chime": "ac3c26072dc04bbf33e6ad3a7bbdd35e82728c7235ced85accad614fea0dd875",
        "Tap": "5a615e4a9c0bd742b277337c72aac0cbcda76cb5ea33d5e1aa888899d34d011b",
        "Bell": "4ab84ce920f7c018799e46091abfd394d6a32e6284b0c16c6efb5f85e74e6f3c",
        "Drop": "23ecfaae70fd240da9923e4c0947249e2b85c627ed13ad99291c6a9611eb650f",
    ]

    /// 装好后的文件名就是通知用的声音名：带品牌前缀，在系统设置的提示音列表里不撞名。
    func prepare(_ sound: Sound) -> UNNotificationSoundName {
        let file = "CuePad \(sound.rawValue.capitalized).caf"
        let name = UNNotificationSoundName(file)
        guard !checked.contains(sound) else { return name }
        do {
            let source = try Data(contentsOf: sound.bundled)
            let target = directory.appending(path: file)
            if (try? Data(contentsOf: target)) != source {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try source.write(to: target, options: .atomic)
            }
            for (old, digest) in Self.retired {
                let file = directory.appending(path: "CuePad \(old).caf")
                guard let data = try? Data(contentsOf: file), SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest else { continue }
                try? FileManager.default.removeItem(at: file)
            }
            checked.insert(sound)
        } catch {
            Logger(subsystem: AppIdentity.id, category: "services")
                .error("提示音没能装进 \(self.directory.path, privacy: .public)：\(String(describing: error), privacy: .public)")
        }
        return name
    }
}
#endif
