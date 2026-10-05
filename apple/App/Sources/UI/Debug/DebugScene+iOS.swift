#if os(iOS) && DEBUG
import CueStore
import SwiftUI

/// iOS 画面：project、older、today、editor、tasks、activity、send、search、trash、settings、capture、sidebar（iPad 展开侧栏）；不给是书架。
/// search 在 iPhone 上是书架的下拉搜索（给了 `-CuePadProject` 则是该项目页内的搜索），出现即聚焦并填入 `-CuePadSearch`。
/// push：停在书架，1.5 秒后像点按一样推入 `-CuePadProject` 的项目页（iPad 也是在书架上推入），录屏核对进入项目页的首帧。
/// taskedit：任务页打开第一条未完成任务的编辑框（与长按"编辑"同一个）。
/// session：打开 `-CuePadSession <会话名>`（默认 homepage）的近况页；send 是从卡片"发到 Mac"先选会话。
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
        case "newsession":
            if split { navigation.select(.activity) } else { navigation.tab = .activity }
            var sheet = Navigation.NewSession()
            if defaults.bool(forKey: "CuePadLaunch"),
               let table = try? await workspace.services.store.projects().first(where: { $0.name == "圆桌" })?.id {
                let token = UUID().uuidString
                if let request = try? await workspace.services.launch(
                    .start(.project(table), prompt: "看看 scheduler 的重连问题", token: token), title: "圆桌", on: "demo-mac") {
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
            if let project { open(.project(project)) }
            navigation.startCapture()
        default:
            if let project, split { open(.project(project)) }
        }
    }

    /// search 画面里该不该激活这个范围的下拉搜索：给了项目时只激活项目页的，否则只激活书架的。
    static func activatesSearch(_ scope: CardSearchScope) -> Bool {
        scene == "search" && (scope == .all) == (defaults.string(forKey: "CuePadProject") == nil)
    }

    /// 两台 Mac 的项目目录绑定：工作室的 Mac 绑了全部带目录的项目，MacBook Air 只绑了 CuePad（新会话里 CuePad 要选 Mac）。
    /// 绑定由本机目录推导，所以先只留 CuePad 的目录发布第二台，再把目录放回去。
    private static func seedBindings(_ store: CueStore, projects: [Project]) async {
        try? await store.publishDirectoryBindings(host: "demo-mac", hostName: "工作室的 Mac Studio")
        guard let directories = try? await store.projectDirectories() else { return }
        let others = projects.filter { $0.name != "CuePad" }.map(\.id)
        for id in others { try? await store.setDirectory(nil, for: id) }
        try? await store.publishDirectoryBindings(host: "demo-air", hostName: "MacBook Air")
        for id in others { if let directory = directories[id] { try? await store.setDirectory(directory, for: id) } }
    }

    /// 演示用的 Mac 端状态：三个 Pi 会话（一个等你确认）、一条等 Mac 接手的请求；圆桌设好目标卡。只在库里还没有时写。
    private static func seedRemote(_ services: AppServices) async {
        let store = services.store
        // 演示库的会话索引已写成历史；这里补的是在线会话，有在线的就是写过了
        guard (try? await store.piSessionPage(.live).items.isEmpty) == true, let projects = try? await store.projects() else { return }
        func project(_ name: String) -> UUID? { projects.first { $0.name == name }?.id }
        let recorder = PiStateRecorder(store: store, hostID: "demo-mac")
        let sessions: [(String, PiWorkState, String?, String?, PiRecap)] = [
            ("atlas", .tool, "bash · pnpm test -- scheduler", "圆桌", PiRecap(
                lastPrompt: "跑一下 scheduler 的测试，失败的话先别改代码，告诉我原因",
                lastReply: "上一轮 12 个用例里有 **2 个失败**：\n\n1. 发言轮次在 5 人以上时，第 6 位的顺序被排到了最前——队列按加入时间排序，但重连的人会拿到新的时间戳。\n2. 登录回调走了旧网关，超时后没有重试。\n\n第一个建议改成按首次加入时间排序，改动在 `scheduler/queue.ts`：\n\n```ts\nqueue.sort((a, b) => a.firstJoinedAt - b.firstJoinedAt)\n```\n\n第二个需要把回调地址换成统一网关。\n\n另外顺手看了一眼覆盖率：scheduler 目录是 71%，主要缺重连和超时两条路径。两个失败修好后，我可以补上这两条的用例，大概再加 6 个测试。\n\n要我先改第一个吗？")),
            ("homepage", .waitingForUser, "要覆盖 public/feed.xml 吗？", "个人网站", PiRecap(
                lastPrompt: "把 RSS 输出改成全文",
                question: PiQuestion(
                    promptID: "demo-prompt", kind: .select, text: "要覆盖 public/feed.xml 吗？", options: ["覆盖", "另存为 feed-full.xml", "取消"]))),
            ("cuepad", .thinking, nil, "CuePad", PiRecap(lastPrompt: "看看投送队列超时的那个 bug")),
            ("notes-edit", .waitingForUser, "编辑提交说明", nil, PiRecap(
                lastPrompt: "写一段提交说明",
                question: PiQuestion(promptID: nil, kind: .unknown("editor"), text: "编辑提交说明\n在编辑器里改好后保存"))),
            ("deploy", .waitingForUser, "部署到生产吗？", nil, PiRecap(
                lastPrompt: "测试都过了就部署",
                question: PiQuestion(promptID: "demo-confirm", kind: .confirm, text: "部署到生产吗？\n会替换当前线上的 1.4.2"))),
            ("review", .delegating, "2 个子代理在审查：计费额度、登录回调", nil, PiRecap(lastPrompt: "让子代理分头审查这两个分支")),
            ("billing", .error, "模型拒绝了请求（400）：prompt is too long", nil, PiRecap(lastPrompt: "把整个 billing 目录读一遍，总结计费规则")),
            ("notes", .settled, nil, nil, PiRecap(
                lastPrompt: "整理一下这周的会议记录", lastReply: "整理好了，放在 notes/2026-W40.md。三件待办：续费域名、评审计费额度、补 scheduler 测试。")),
            ("piwork", .settled, nil, nil, PiRecap(
                lastPrompt: "列出 piwork 目录下的文件", lastReply: "目录里有 3 个文件：\n- README.md\n- notes.txt\n- todo.md")),
        ]
        // 历史里再加两个带近况的：一个正在请 Mac 继续，一个不在项目里
        let history: [(String, String?, PiRecap)] = [
            ("landing-copy", "个人网站", PiRecap(lastPrompt: "把首页标题换成新文案", lastReply: "改好了，首页标题现在是「把想法写成卡片」。")),
            ("weekly", nil, PiRecap(lastPrompt: "汇总这周的提交", lastReply: "这周 23 个提交，主要是同步和 Pi 页。")),
        ]
        for (id, name, recap) in history {
            try? await recorder.update(sessionID: id, state: .settled, detail: nil, title: id, folder: id, projectID: name.flatMap(project), recap: recap)
            try? await recorder.end(sessionID: id)
        }
        for (id, state, detail, name, recap) in sessions {
            try? await recorder.update(
                sessionID: id, state: state, detail: detail, title: id, folder: id, projectID: name.flatMap(project), recap: recap)
        }
        try? await recorder.end(sessionID: "piwork")
        if let table = project("圆桌"), let goal = try? await store.cards(in: table).first(where: { $0.body.hasPrefix("目标") }) {
            try? await store.setGoal(goal.id, for: table)
        }
        await seedBindings(store, projects: projects)
        let extra = defaults.integer(forKey: "CuePadHistory")
        for index in 0..<extra {
            let id = "history-\(index + 1)"
            let name = ["CuePad", "圆桌", nil][index % 3]
            let ended = Date.now.addingTimeInterval(-Double(index + 1) * 8 * 3600)
            let past = PiStateRecorder(store: store, hostID: "demo-mac", timing: Timing(now: { ended }, sleep: { _ in }))
            try? await past.update(
                sessionID: id, state: .settled, detail: nil, title: "历史会话 \(index + 1)", folder: id, projectID: name.flatMap(project),
                recap: PiRecap(lastPrompt: "第 \(index + 1) 个", lastReply: "做完了"))
            try? await past.end(sessionID: id)
        }
        let states = (try? await store.piSessionPage(PiSessionQuery(limit: 100)).items.map(\.state)) ?? []
        if let atlas = states.first(where: { $0.sessionID == "atlas" }) {
            _ = try? await services.requestMacDelivery("评审：计费额度\n审查 {{分支}} 中计费额度相关改动。", to: atlas, mode: .followUp)
        }
        if let landing = states.first(where: { $0.sessionID == "landing-copy" }) {
            _ = try? await services.launch(.resume(sessionID: landing.sessionID), title: landing.title, on: landing.hostID)
        }
        if let cuepad = states.first(where: { $0.sessionID == "cuepad" }) {
            _ = try? await services.requestMacDelivery("超时后先重试一次，还失败再报错", to: cuepad, mode: .steer)
        }
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
