import CueStore
import Foundation

/// 提示词能交给哪些在线会话（iPhone 的发给 Agent 输入框与 Mac 的发送目标、会话菜单共用这一份）：所有 Mac 上在线的会话
/// （`LiveSessions`，不分在哪台 Mac；含托管着、进程歇着的，发话时 Mac 在后台唤醒），本项目的在前，再按要你注意的先后。
/// 已结束的不在其中（Mac 上刚结束的另列，发送时在后台唤醒）。
/// 发出去的路也是一条：写一条指定会话所在 Mac 的投送请求（`AppServices.requestMacDelivery`）；Mac 上发给本机的会话时
/// 请求的执行者就是本机，所以本机的会话不必另走一条路。
enum HandOffTargets {
    static func sessions(_ live: [PiSessionListItem], project: UUID?) -> [PiSessionListItem] {
        func key(_ item: PiSessionListItem) -> (Int, Int) {
            (item.state.projectID == project && project != nil ? 1 : 0, PiShown(item.state, delivery: item.delivery).urgency)
        }
        return live.sorted { key($0) > key($1) }
    }

    /// 菜单里一项的写法：会话名、所在、状态。
    static func title(_ item: PiSessionListItem, project: Project?, shown: PiShown) -> Dotted {
        Dotted(item.state.title, PiPlace.name(of: item.state, project: project), shown.label)
    }
}
