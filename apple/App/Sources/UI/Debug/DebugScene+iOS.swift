#if os(iOS) && DEBUG
import CueStore
import SwiftUI

/// iOS 画面：project、older、today、editor、tasks、activity、send、search、trash、settings、capture、sidebar（iPad 展开侧栏）；不给是书架。
/// push：停在书架，1.5 秒后像点按一样推入 `-CuePadProject` 的项目页（iPad 是在侧栏选中），录屏核对进入项目页的首帧。
/// roundtrip：iPhone 在该项目页上打开一张卡、2.5 秒后返回（核对标签栏随转场隐藏与出现）；iPad 进入搜索、2 秒后退出（核对来回不闪空白页）。
/// iPad 上 tasks、activity 打开右侧面板。演示库另写入 Mac 同步来的 Pi 会话状态与一条发到 Mac 的请求。
extension DebugScene {
    static func prepare(_ workspace: Workspace, _ navigation: Navigation) async {
        let project = await prepareLibrary(workspace)
        if defaults.bool(forKey: "CuePadDemo") { await seedRemote(workspace.services) }
        let split = navigation.layout == .split
        func open(_ route: Navigation.Route) {
            if split { navigation.select(route) } else { navigation.projectsPath = [route] }
        }
        func openCard() async {
            if let project { open(.project(project)) }
            if let card = await card(in: project, store: workspace.services.store) { navigation.push(.card(card)) }
        }
        switch scene {
        case "project", "older": if let project { open(.project(project)) }
        case "roundtrip":
            guard let project else { break }
            open(.project(project))
            try? await Task.sleep(for: .seconds(1.5))
            if split {
                navigation.openSearch()
                try? await Task.sleep(for: .seconds(2))
                navigation.closeSearch()
            } else if let card = await card(in: project, store: workspace.services.store) {
                navigation.push(.card(card))
                try? await Task.sleep(for: .seconds(2.5))
                navigation.projectsPath.removeLast()
            }
        case "push":
            try? await Task.sleep(for: .seconds(1.5))
            if let project { if split { navigation.select(.project(project)) } else { navigation.push(.project(project)) } }
        case "sidebar":
            if let project { open(.project(project)) }
            navigation.sidebar = .all
        case "today": open(.today)
        case "trash": open(.trash)
        case "settings": open(.settings)
        case "editor": await openCard()
        case "send":
            await openCard()
            if let id = await card(in: project, store: workspace.services.store),
               let card = try? await workspace.services.store.card(id) {
                navigation.outbox = Navigation.Outbox(content: Outgoing.text(of: card), card: id, project: project)
            }
        case "tasks":
            if let project { open(.project(project)) }
            if split { navigation.panel = .tasks } else { navigation.tab = .tasks }
        case "activity":
            if let project { open(.project(project)) }
            if split { navigation.panel = .activity } else { navigation.tab = .activity }
        case "search":
            if split { navigation.select(.search) } else { navigation.tab = .search }
        case "capture":
            if let project { open(.project(project)) }
            navigation.startCapture()
        default:
            if let project, split { open(.project(project)) }
        }
    }

    /// 演示用的 Mac 端状态：三个 Pi 会话（一个等你确认）、一条等 Mac 接手的请求；圆桌设好目标卡。只在库里还没有时写。
    private static func seedRemote(_ services: AppServices) async {
        let store = services.store
        guard (try? await store.piSessionStates().isEmpty) == true, let projects = try? await store.projects() else { return }
        func project(_ name: String) -> UUID? { projects.first { $0.name == name }?.id }
        let recorder = PiStateRecorder(store: store, hostID: "demo-mac")
        let sessions: [(String, PiWorkState, String?, String)] = [
            ("atlas", .tool, "bash · pnpm test -- scheduler", "圆桌"),
            ("homepage", .waitingForUser, "要覆盖 public/feed.xml 吗？", "个人网站"),
            ("cuepad", .thinking, nil, "CuePad"),
        ]
        for (id, state, detail, name) in sessions {
            try? await recorder.update(sessionID: id, state: state, detail: detail, title: id, projectID: project(name))
        }
        if let table = project("圆桌"), let goal = try? await store.cards(in: table).first(where: { $0.body.hasPrefix("目标") }) {
            try? await store.setGoal(goal.id, for: table)
        }
        if let atlas = try? await store.piSessionStates().first(where: { $0.sessionID == "atlas" }) {
            _ = try? await services.requestMacDelivery("评审：计费额度\n审查 {{分支}} 中计费额度相关改动。", to: atlas, mode: .followUp)
        }
    }
}
#endif
