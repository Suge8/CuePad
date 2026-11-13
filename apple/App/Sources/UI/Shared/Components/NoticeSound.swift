import AudioToolbox

/// 提示条出现时的那一声（`Sounds/ui-<名字>.caf`，合成源是 `design/tools/notification-sounds.py`）：只跟着看得见的提示响，由显示它的那一颗播（`NoticeCapsule`）。
/// 走系统的界面音：Mac 听"声音 › 播放用户界面声音效果"与提示音量，手机与 iPad 听静音键——开关在系统那里，App 不另设一个。
/// 只报个结果的提示（已复制、已记下）不出声：一天上百次，响了是打扰。
enum NoticeSound: String {
    /// 做完一件任务。
    case complete
    /// 做了一件能撤的事（归档、删除、合并）。
    case act
    case undo
    case fail

    private static var loaded: [NoticeSound: SystemSoundID] = [:]

    func play() {
        if Self.loaded[self] == nil, let url = Bundle.main.url(forResource: "ui-\(rawValue)", withExtension: "caf") {
            var id: SystemSoundID = 0
            AudioServicesCreateSystemSoundID(url as CFURL, &id)
            Self.loaded[self] = id
        }
        if let id = Self.loaded[self] { AudioServicesPlaySystemSound(id) }
    }
}
