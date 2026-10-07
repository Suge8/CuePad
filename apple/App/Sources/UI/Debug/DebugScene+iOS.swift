#if os(iOS) && DEBUG
import CueStore
import CueSync
import SwiftUI
import UIKit

/// iOS 画面：project、older、inbox、editor、tasks、agent、send、search、trash、settings、capture、sidebar（iPad 展开侧栏）；不给是书架。
/// search 在 iPhone 上是书架的下拉搜索（给了 `-CuePadProject` 则是该项目页内的搜索），出现即聚焦并填入 `-CuePadSearch`。
/// push：停在书架，1.5 秒后像点按一样推入 `-CuePadProject` 的项目页（iPad 也是在书架上推入），录屏核对推入的首帧；
/// 给了 `-CuePadPush <tasks|settings|trash|inbox|card>` 时推入的是那一页（card 是该项目里的一张卡）。
/// tasks：跨项目任务页（iPhone 在项目标签里推入，iPad 选中侧栏）；taskedit 在任务页打开第一条未完成任务的编辑框（与长按"编辑"同一个）。
/// session：打开 `-CuePadSession <会话名>`（默认 homepage）的近况页（给了 `-CuePadPushAfter <秒>` 时先停在 Agent 页，到时再推入）；给了 `-CuePadChatGrow YES` 时之后每 4 秒进来一条 Pi 的回答
/// （核对往上翻后出"新消息"、贴底时跟到底），给了 `-CuePadChatBulk <N>` 时推入后整批进来 N 轮长对话（核对整批到达时停在最新）；send 是从卡片"发到 Mac"先选会话。
/// projectform：项目表单（给了 `-CuePadProject` 是编辑该项目，否则新建）。
/// searchkey：iPhone 停在 Agent 标签，1.5 秒后走 ⌘K（回到书架并聚焦下拉搜索）。
/// roundtrip：iPhone 在该项目页上打开一张卡、2.5 秒后返回（核对标签栏随转场隐藏与出现）；iPad 进入搜索、2 秒后退出（核对来回不闪空白页）。
/// agent 给了 `-CuePadHistory <N>`：演示库再写 N 个已结束会话（每隔 8 小时结束一个，分落在今天到更早），
/// Agent 页打开就滚到底（看历史滑到底读下一页；同时给了 `-CuePadSearch` 时停在顶上）。
/// projectagent：在 `-CuePadProject` 的项目页上推入它的 Agent 页（筛着这个项目）。
/// sendflow：打开 `-CuePadSession`（默认 notes）的会话页，2 秒后写出一句话、随即返回 Agent 列表（配 `-CuePadDemoMac YES` 看状态流转）。
/// newsession：Agent 页上打开新会话面板；给了 `-CuePadLaunch YES` 则已经替你在圆桌发出（看送达中）。
/// `-CuePadDemoMac YES`：发给演示 Mac（demo-mac）上会话的话由它慢慢接手、送达、再回状态（见 `runDemoMac`）。
/// iPad 上 agent 打开右侧 Agent 面板。演示库另写入 Mac 同步来的 Pi 会话状态（含历史）与几条发到 Mac 的请求。
extension DebugScene {
    static func prepare(_ workspace: Workspace, _ navigation: Navigation) async {
        dumpAccessibilityIfAsked()
        let project = await prepareLibrary(workspace)
        if defaults.bool(forKey: "CuePadDemo") { await seedRemote(workspace.services) }
        if defaults.bool(forKey: "CuePadDemoMac") { Task { await runDemoMac(workspace.services.store) } }
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
            // 标签栏布局按 ⌘K：在 Agent 标签按，应回到书架并聚焦下拉搜索
            navigation.tab = .agent
            try? await Task.sleep(for: .seconds(1.5))
            navigation.searchCurrentPage()
        case "push":
            if split { navigation.select(.shelf) }
            try? await Task.sleep(for: .seconds(1.5))
            switch defaults.string(forKey: "CuePadPush") {
            case "tasks": navigation.push(.tasks)
            case "settings": navigation.push(.settings)
            case "trash": navigation.push(.trash)
            case "inbox": navigation.push(.inbox)
            case "card": if let card = await card(in: project, store: workspace.services.store) { navigation.push(.card(card)) }
            default: if let project { navigation.push(.project(project)) }
            }
        case "sidebar":
            if let project { open(.project(project)) }
            navigation.sidebar = .all
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
                    navigation.openSession(session.id, seed: session, draft: outbox)
                } else {
                    navigation.outbox = outbox
                }
            }
        case "tasks", "taskedit":
            navigation.showTasks()
        case "session":
            // 打开 -CuePadSession（会话名，默认 homepage）的近况页，iPhone 在 Agent 标签里
            let title = defaults.string(forKey: "CuePadSession") ?? "homepage"
            guard let session = try? await workspace.services.store.piSessionPage(PiSessionQuery(text: title)).items.first(where: { $0.state.title == title })?.state else { break }
            if split { navigation.select(.agent) } else { navigation.tab = .agent }
            // -CuePadPushAfter <秒>：先停在 Agent 页，过一会儿再像点了会话行一样推入（录屏核对推入的首帧）
            let delay = defaults.double(forKey: "CuePadPushAfter")
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            navigation.push(.session(session.id, seed: session))
            if defaults.bool(forKey: "CuePadChatGrow") { Task { await growChat(session.sessionID, store: workspace.services.store) } }
            let bulk = defaults.integer(forKey: "CuePadChatBulk")
            if bulk > 0 { Task { await bulkChat(session.sessionID, count: bulk, store: workspace.services.store) } }
        case "sendflow":
            // 停在会话页 → 像点了发送一样写出请求（隔离模式没有同步、发送钮不可用）→ 返回 Agent 列表看状态流转；配 -CuePadDemoMac YES
            let title = defaults.string(forKey: "CuePadSession") ?? "notes"
            guard let session = try? await workspace.services.store.piSessionPage(PiSessionQuery(text: title)).items.first(where: { $0.state.title == title })?.state else { break }
            if split { navigation.select(.agent) } else { navigation.tab = .agent }
            navigation.push(.session(session.id, seed: session))
            try? await Task.sleep(for: .seconds(2))
            _ = try? await workspace.services.requestMacDelivery("看一下这周的待办", to: session, mode: .send)
            try? await Task.sleep(for: .seconds(0.4))
            if split { navigation.splitPath.removeLast() } else { navigation.agentPath.removeLast() }
        case "newsession":
            if split { navigation.select(.agent) } else { navigation.tab = .agent }
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
        case "projectagent":
            // 从项目页的"全部 N 个会话"进来的 Agent 页：先筛着这个项目
            if let project { open(.project(project)); navigation.push(.projectSessions(project)) }
        case "agent":
            if let project { open(.project(project)) }
            if split { navigation.agentPanel = true } else { navigation.tab = .agent }
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

    /// `-CuePadComposer <cards|attachments>`（配 session、newsession 画面）：输入框出现时 cards 打开选卡片面板，
    /// attachments 带上一张卡片（`-CuePadCard` 挑哪张）并放进两张演示图片。＋ 菜单是系统菜单、不能代为展开：
    /// 截图时按一下 ＋（iPhone 17 Pro 回复框：`axe touch -x 37 -y 810 --down --up --delay 0.15`；axe 的 tap 太快，菜单不开）。
    static func presetComposer(_ draft: Binding<ComposerDraft>, source: Binding<ComposerSource?>, store: CueStore) async {
        switch defaults.string(forKey: "CuePadComposer") {
        case "cards":
            // 等推入页面的转场走完再弹，转场中弹出的面板会被系统丢掉
            try? await Task.sleep(for: .seconds(1))
            source.wrappedValue = .cards
        case "attachments":
            // 先挑未归档里的，没有再挑第一个项目里的
            var id = await card(in: nil, store: store)
            if id == nil, let project = try? await store.projects().first { id = await card(in: project.id, store: store) }
            if let id, let card = try? await store.card(id) {
                draft.wrappedValue.attachment = Navigation.Outbox(content: Outgoing.text(of: card), card: card.id, project: card.projectID)
            }
            draft.wrappedValue.images = [UIColor(red: 0.85, green: 0.47, blue: 0.29, alpha: 1), UIColor(red: 0.25, green: 0.56, blue: 0.72, alpha: 1)]
                .map { color in
                    PickedImage(data: UIGraphicsImageRenderer(size: CGSize(width: 240, height: 180)).pngData { context in
                        color.setFill()
                        context.fill(CGRect(x: 0, y: 0, width: 240, height: 180))
                    })
                }
        default:
            break
        }
    }

    /// `-CuePadAlertStatus <on|pending|denied|undetermined|registerFailed|subscribeFailed>`：设置页"Pi 通知"一行按这个状态显示
    /// （演示模式没有同步引擎、真实状态出不来）。
    static var alertStatus: PiAlertStatus? {
        switch defaults.string(forKey: "CuePadAlertStatus") {
        case "on": PiAlertStatus(authorization: .authorized, registration: .registered, subscription: .active)
        case "pending": PiAlertStatus(authorization: .authorized, registration: .pending, subscription: .off)
        case "denied": PiAlertStatus(authorization: .denied, registration: .pending, subscription: .off)
        case "undetermined": PiAlertStatus(authorization: .notDetermined, registration: .pending, subscription: .off)
        case "registerFailed": PiAlertStatus(authorization: .authorized, registration: .failed("没有连接到 Apple 推送服务"), subscription: .off)
        case "subscribeFailed": PiAlertStatus(authorization: .authorized, registration: .registered, subscription: .failed("iCloud 账号不可用"))
        default: nil
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
