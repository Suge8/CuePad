#if os(iOS) && DEBUG
import CueStore
import SwiftUI

/// iOS 画面：project、older、today、inbox、editor、tasks、activity、send、search、trash、settings、capture、sidebar（iPad 展开侧栏）；不给是书架。
/// search 在 iPhone 上是书架的下拉搜索（给了 `-CuePadProject` 则是该项目页内的搜索），出现即聚焦并填入 `-CuePadSearch`。
/// push：停在书架，1.5 秒后像点按一样推入 `-CuePadProject` 的项目页（iPad 也是在书架上推入），录屏核对进入项目页的首帧。
/// taskedit：任务页打开第一条未完成任务的编辑框（与长按"编辑"同一个）。
/// session：打开 `-CuePadSession <会话名>`（默认 homepage）的近况页；给了 `-CuePadChatGrow YES` 时之后每 4 秒进来一条 Pi 的回答
/// （核对往上翻后出"新消息"、贴底时跟到底）；send 是从卡片"发到 Mac"先选会话。
/// projectform：项目表单（给了 `-CuePadProject` 是编辑该项目，否则新建）。
/// searchkey：iPhone 停在任务页，1.5 秒后走 ⌘K（回到书架并聚焦下拉搜索）。
/// roundtrip：iPhone 在该项目页上打开一张卡、2.5 秒后返回（核对标签栏随转场隐藏与出现）；iPad 进入搜索、2 秒后退出（核对来回不闪空白页）。
/// activity 给了 `-CuePadHistory <N>`：演示库再写 N 个已结束会话（每隔 8 小时结束一个，分落在今天到更早），
/// Pi 页打开就滚到底（看历史滑到底读下一页；同时给了 `-CuePadSearch` 时停在顶上）。
/// newsession：Pi 页上打开新会话面板；给了 `-CuePadLaunch YES` 则已经替你在圆桌发出（看送达中）。
/// iPad 上 tasks、activity 打开右侧面板。演示库另写入 Mac 同步来的 Pi 会话状态（含历史）与几条发到 Mac 的请求。
extension DebugScene {
    static func prepare(_ workspace: Workspace, _ navigation: Navigation) async {
        dumpAccessibilityIfAsked()
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
        case "projectform":
            // 给了项目是编辑它，否则新建
            let existing = if let project { try? await workspace.services.store.project(project) } else { Project?.none }
            navigation.projectForm = .init(project: existing)
        case "searchkey":
            // 标签栏布局按 ⌘K：在任务页按，应回到书架并聚焦下拉搜索
            navigation.tab = .tasks
            try? await Task.sleep(for: .seconds(1.5))
            navigation.searchCurrentPage()
        case "push":
            if split { navigation.select(.shelf) }
            try? await Task.sleep(for: .seconds(1.5))
            if let project { navigation.push(.project(project)) }
        case "sidebar":
            if let project { open(.project(project)) }
            navigation.sidebar = .all
        case "today": open(.today)
        case "inbox": open(.inbox)
        case "trash": open(.trash)
        case "settings": open(.settings)
        case "editor": await openCard()
        case "send":
            await openCard()
            if let id = await card(in: project, store: workspace.services.store),
               let card = try? await workspace.services.store.card(id) {
                let outbox = Navigation.Outbox(content: Outgoing.text(of: card), card: id, project: project)
                // 给了 -CuePadSession 就当已选好会话，直接进它的近况页（卡片预填在回复框里）
                if let title = defaults.string(forKey: "CuePadSession"),
                   let session = try? await workspace.services.store.piSessionPage(PiSessionQuery(text: title)).items.first(where: { $0.state.title == title })?.state {
                    navigation.openSession(session.id, draft: outbox)
                } else {
                    navigation.outbox = outbox
                }
            }
        case "tasks", "taskedit":
            if let project { open(.project(project)) }
            if split { navigation.panel = .tasks } else { navigation.tab = .tasks }
        case "session":
            // 打开 -CuePadSession（会话名，默认 homepage）的近况页，iPhone 在活动标签里
            let title = defaults.string(forKey: "CuePadSession") ?? "homepage"
            guard let session = try? await workspace.services.store.piSessionPage(PiSessionQuery(text: title)).items.first(where: { $0.state.title == title })?.state else { break }
            if split { navigation.select(.activity) } else { navigation.tab = .activity }
            navigation.push(.session(session.id))
            if defaults.bool(forKey: "CuePadChatGrow") { Task { await growChat(session.sessionID, store: workspace.services.store) } }
        case "newsession":
            if split { navigation.select(.activity) } else { navigation.tab = .activity }
            var sheet = Navigation.NewSession()
            if defaults.bool(forKey: "CuePadLaunch"),
               let table = try? await workspace.services.store.projects().first(where: { $0.name == "圆桌" })?.id {
                let token = UUID().uuidString
                if let request = try? await workspace.services.launch(
                    PiLaunch(place: .project(table), prompt: "看看 scheduler 的重连问题", token: token), title: "圆桌", on: "demo-mac") {
                    sheet.launched = .init(request: request.id, token: token)
                }
            }
            navigation.newSession = sheet
        case "activity":
            if let project { open(.project(project)) }
            if split { navigation.panel = .activity } else { navigation.tab = .activity }
        case "search":
            // iPhone：书架（给了项目则是该项目页）的下拉搜索在出现时自己聚焦，见 CardSearch
            if split { navigation.select(.search) } else if let project { open(.project(project)) }
        case "capture":
            // 等推入的项目页把它的随手记放上屏幕，再像点了它一样打开
            if let project { open(.project(project)) }
            try? await Task.sleep(for: .seconds(1))
            navigation.startCapture()
        default:
            if let project, split { open(.project(project)) }
        }
    }

    /// search 画面里该不该激活这个范围的下拉搜索：给了项目时只激活项目页的，否则只激活书架的。
    static func activatesSearch(_ scope: CardSearchScope) -> Bool {
        scene == "search" && (scope == .all) == (defaults.string(forKey: "CuePadProject") == nil)
    }
}
#endif

#if os(iOS) && DEBUG
import UIKit

/// `-CuePadAXDump YES`：界面起来 4 秒后把读屏看到的元素（标签、值、特征）按顺序写进资料库目录的
/// `ax-dump.txt`，给没有 UI 测试目标、没有 Simulator 图形界面时核对无障碍。
extension DebugScene {
    static func dumpAccessibilityIfAsked() {
        guard defaults.bool(forKey: "CuePadAXDump"), let dir = ProcessInfo.processInfo.environment["CUEPAD_LIBRARY_DIR"] else { return }
        // 和 XCTest 一样打开"自动化"无障碍：SwiftUI 只在有辅助技术时才建出元素树
        if let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let symbol = dlsym(handle, "_AXSSetAutomationEnabled") {
            unsafeBitCast(symbol, to: (@convention(c) (Int32) -> Void).self)(1)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            var lines: [String] = []
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                for window in scene.windows where !window.isHidden { collect(window, into: &lines) }
            }
            try? lines.joined(separator: "\n").write(toFile: dir + "/ax-dump.txt", atomically: true, encoding: .utf8)
        }
    }

    private static func collect(_ node: NSObject, into lines: inout [String]) {
        if node.isAccessibilityElement {
            let traits = node.accessibilityTraits
            let kind = traits.contains(.button) ? "Button" : traits.contains(.header) ? "Header" : traits.contains(.staticText) ? "Text"
                : traits.contains(.image) ? "Image" : "Element"
            let value = node.accessibilityValue.map { " = \($0)" } ?? ""
            lines.append("\(kind) '\(node.accessibilityLabel ?? "")'\(value)")
            return
        }
        if let elements = node.accessibilityElements as? [NSObject] {
            for element in elements { collect(element, into: &lines) }
        } else if let view = node as? UIView {
            for sub in view.subviews where !sub.isHidden && sub.alpha > 0 { collect(sub, into: &lines) }
        }
    }
}
#endif
