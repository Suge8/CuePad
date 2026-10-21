import CueStore
import Foundation

/// 任务能交给哪些在线会话（iPhone 的发给 Agent 输入框与 Mac 的发送目标、会话菜单共用这一份）：所有 Mac 上在线的会话
/// （`LiveSessions`，不分在哪台 Mac；含托管着、进程歇着的，发话时 Mac 在后台唤醒），本项目的在前，再按要你注意的先后。
/// 已结束的不在其中（Mac 上刚结束的另列）；发出去都是写一条给会话所在 Mac 的投送请求（`Workspace.speak`），本机的会话也一样。
enum HandOffTargets {
    static func sessions(_ live: [PiSessionListItem], project: UUID?, at moment: Speech.Moment) -> [PiSessionListItem] {
        func key(_ item: PiSessionListItem) -> (Int, Int) {
            (item.state.projectID == project && project != nil ? 1 : 0, PiShown(item.state, delivery: item.delivery, at: moment).urgency)
        }
        return live.sorted { key($0) > key($1) }
    }

    static func title(_ item: PiSessionListItem, project: Project?, shown: PiShown) -> Dotted {
        Dotted(item.state.title, item.state.agentMark, PiPlace.name(of: item.state, project: project), shown.label)
    }
}
