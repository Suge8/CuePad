#if os(macOS)
import CueStore
import Foundation

/// ⌘K"会话"范围里的一组结果。
struct SessionGroup: Equatable {
    enum Key: Hashable {
        case project(UUID)
        /// 没绑项目的会话按文件夹归组；nil 是不知道在哪的（旧记录没有文件夹名）。
        case folder(String?)
    }

    let key: Key
    let sessions: [PiSessionState]

    static func grouped(_ sessions: [PiSessionState]) -> [SessionGroup] {
        []
    }
}
#endif
