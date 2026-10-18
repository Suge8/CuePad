import Foundation

extension Route {
    /// 正看着这一页时，这个会话（记录 id）的提示已经不用说了：就是它的会话页，或 Agent 整页（那一行已经在变）。
    /// 两端只有这一条：Mac 不发系统通知（`Workspace.isWatching`），手机不弹前台横幅、弹出后进来就撤下（`Navigation.showsAlert`）。
    func covers(session id: UUID) -> Bool { self == .agent || self == .session(id) }
}
