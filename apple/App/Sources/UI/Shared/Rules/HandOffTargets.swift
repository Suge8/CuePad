import CueStore
import Foundation

/// 含托管着、进程歇着的（发话时 Mac 在后台唤醒）；已结束的不在其中（Mac 上刚结束的另列）。
enum HandOffTargets {
    static func sessions(_ live: [SessionListItem], project: UUID?, at moment: Speech.Moment) -> [SessionListItem] {
        func key(_ item: SessionListItem) -> (Int, Int) {
            (item.state.projectID == project && project != nil ? 1 : 0, SessionShown(item.state, delivery: item.delivery, at: moment).urgency)
        }
        return live.sorted { key($0) > key($1) }
    }

    static func title(_ item: SessionListItem, project: Project?, shown: SessionShown) -> Dotted {
        Dotted(item.state.title, item.state.agentMark, SessionPlace.name(of: item.state, project: project), shown.label)
    }
}
