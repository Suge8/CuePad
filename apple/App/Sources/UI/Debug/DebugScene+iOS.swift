#if os(iOS) && DEBUG
import CueStore
import CueSync
import SwiftUI
import UIKit

/// iOS 画面：project、older、inbox、editor、tasks、agent、send、search、trash、archive、settings、capture、sidebar（iPad 展开侧栏）；不给是书架。
/// search 在 iPhone 上是书架顶上的搜索框（给了 `-CuePadProject` 则是该项目页的下拉搜索），出现即聚焦并填入 `-CuePadSearch`。
/// push：停在书架，1.5 秒后像点按一样推入 `-CuePadProject` 的项目页（iPad 也是在书架上推入），录屏核对推入的首帧；
/// 给了 `-CuePadPush <tasks|settings|trash|inbox|card>` 时推入的是那一页（card 是该项目里的一张卡）。
/// tasks：跨项目任务页（iPhone 在项目标签里推入，iPad 选中侧栏）；task 停在书架并在浮窗里打开"正在推进"的第一条（没有就是第一条待办；给了 `-CuePadTask <标题开头>` 是那一条）。
/// taskflow：书架上走一遍任务的后半程（配 `-CuePadDemoMac YES`）：圆桌的"补重连用例"在浮窗里打开 → 交给演示 Mac 的 notes 会话、收起浮窗 →
/// 送达后"正在推进"出现这条并带会话状态 → 再打开浮窗标为完成。前半程（随手记、轻扫要做、浮窗里改正文）用真实手势录。
/// session：打开 `-CuePadSession <会话名>`（默认 homepage）的近况页（给了 `-CuePadPushAfter <秒>` 时先停在 Agent 页，到时再推入）；给了 `-CuePadChatGrow YES` 时之后每 4 秒进来一条 Pi 的回答
/// （核对往上翻远后"回到最新"圆钮带点、贴底时跟到底），给了 `-CuePadChatBulk <N>` 时推入后整批进来 N 轮长对话（核对整批到达时停在最新）；send 是从卡片"发到 Mac"先选会话。
/// projectform：项目表单（给了 `-CuePadProject` 是编辑该项目，否则新建）。
/// alert：停在书架（配 `-CuePadDemo YES`），2.5 秒后 atlas 从工作中做完、9 秒后 cuepad 进入等你确认——Mac 同步来的状态转换，核对 App 内的前台提示横幅；
/// 给了 `-CuePadSession <会话名>` 时先打开那个会话页（核对正看着的会话不弹）。
/// notifytap：复现点通知——经 `PiAlertCenter.receive` 交付与生产同形的通知 userInfo，走与点锁屏通知同一条路由代码：先打开 `-CuePadSession` 的会话页
/// （或 `-CuePadNotifyFromCard YES` 先打开一张卡），再按 `-CuePadNotifyTaps "会话名@秒,…"` 依次点。冷启动被通知拉起用 `-CuePadColdTap <会话记录 id>`（在界面出现前交付）。
/// searchkey：iPhone 停在 Agent 标签，1.5 秒后走 ⌘K（回到书架并聚焦顶上的搜索框）。
/// roundtrip：iPhone 在该项目页上打开一张卡、2.5 秒后返回（核对标签栏随转场隐藏与出现）；iPad 进入搜索、2 秒后退出（核对来回不闪空白页）。
/// agent 给了 `-CuePadHistory <N>`：演示库再写 N 个已结束会话（每隔 8 小时结束一个，分落在今天到更早），
/// Agent 页打开就滚到底（看历史滑到底读下一页；同时给了 `-CuePadSearch` 时停在顶上）。
/// projectagent：在 `-CuePadProject` 的项目页上推入它的 Agent 页（筛着这个项目）。
/// sendflow：打开 `-CuePadSession`（默认 notes）的会话页，2 秒后写出一句话、随即返回 Agent 列表（配 `-CuePadDemoMac YES` 看状态流转）。
/// style：视觉样板（`StyleBoard`）盖在最上层。
/// newsession：Agent 页上浮起新会话输入框；给了 `-CuePadLaunch YES` 则已经替你在圆桌发出（看送达中）。
/// `-CuePadDemoMac YES`：发给演示 Mac（demo-mac）上会话的话由它慢慢接手、送达、再回状态（见 `runDemoMac`）。
/// iPad 上 agent 打开右侧 Agent 面板。演示库另写入 Mac 同步来的 Pi 会话状态（含历史）与几条发到 Mac 的请求。
extension DebugScene {
    /// 与生产同形的 CloudKit 查询订阅通知的 userInfo（记录 id 是会话记录 id）。
    static func notification(session: String) -> [AnyHashable: Any] {
        [
            "aps": ["alert": ["loc-key": "pi_alert_settled"]],
            "ck": ["ce": 2, "cid": "iCloud.com.sugeh.cuepad", "nid": UUID().uuidString,
                   "qry": ["dbs": 1, "fo": 1, "rid": session.lowercased(), "sid": "cuepad.pi.settled", "zid": "CuePad", "zoid": "__defaultOwner__"]],
        ]
    }

    static func prepare(_ workspace: Workspace, _ navigation: Navigation, _ alerts: PiAlertCenter) async {
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
        case "alert":
            let store = workspace.services.store
            if let title = defaults.string(forKey: "CuePadSession"),
               let session = try? await store.piSessionPage(PiSessionQuery(text: title)).items.first(where: { $0.state.title == title })?.state {
                if split { navigation.select(.agent) } else { navigation.tab = .agent }
                navigation.openSession(session.id, sessionID: session.sessionID, store: store)
            }
            let recorder = PiStateRecorder(store: store, hostID: "demo-mac")
            try? await Task.sleep(for: .seconds(2.5))
            try? await recorder.update(sessionID: "atlas", state: .settled, title: "atlas", folder: "圆桌")
            try? await Task.sleep(for: .seconds(6.5))
            let question = PiQuestion(promptID: "demo-alert", kind: .select, text: "要重跑全部测试吗？", options: ["重跑", "跳过"])
            try? await recorder.update(sessionID: "cuepad", state: .waitingForUser, title: "cuepad", folder: "CuePad", question: question)
        case "notifytap":
            // 复现点通知：先打开 -CuePadSession 的会话页（没给就留在书架），再按 -CuePadNotifyTaps "会话名@秒,…" 依次投递与生产同形的通知点击
            let store = workspace.services.store
            func session(_ title: String) async -> PiSessionState? {
                try? await store.piSessionPage(PiSessionQuery(text: title)).items.first(where: { $0.state.title == title })?.state
            }
            if let title = defaults.string(forKey: "CuePadSession"), let opened = await session(title) {
                if split { navigation.select(.agent) } else { navigation.tab = .agent }
                navigation.openSession(opened.id, sessionID: opened.sessionID, store: store)
            } else if defaults.bool(forKey: "CuePadNotifyFromCard") {
                await openCard()
            }
            var elapsed = 0.0
            for spec in (defaults.string(forKey: "CuePadNotifyTaps") ?? "").split(separator: ",") {
                let parts = spec.split(separator: "@")
                guard parts.count == 2, let at = Double(parts[1]), let target = await session(String(parts[0])) else { continue }
                try? await Task.sleep(for: .seconds(max(0, at - elapsed)))
                elapsed = max(elapsed, at)
                alerts.receive(notification(session: target.id.uuidString))
            }
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
        case "archive": open(.archive)
        case "settings": open(.settings)
        case "editor": await openCard()
        case "send":
            await openCard()
            if let id = await card(in: project, store: workspace.services.store),
               let card = try? await workspace.services.store.card(id) {
                let outbox = Outbox(content: Outgoing.text(of: card), card: id, project: project)
                // 给了 -CuePadSession 就当已选好会话，直接进它的近况页（卡片预填在回复框里）
                if let title = defaults.string(forKey: "CuePadSession"),
                   let session = try? await workspace.services.store.piSessionPage(PiSessionQuery(text: title)).items.first(where: { $0.state.title == title })?.state {
                    navigation.openSession(session.id, sessionID: session.sessionID, draft: outbox, store: workspace.services.store)
                } else {
                    navigation.outbox = outbox
                }
            }
        case "tasks":
            navigation.showTasks()
        case "task":
            let store = workspace.services.store
            let tasks = (try? await store.tasks(.inProgress, .todo).flatMap(\.tasks)) ?? []
            // 给了 -CuePadTask <标题开头> 打开那一条，否则进行中的第一条
            let named = defaults.string(forKey: "CuePadTask").flatMap { prefix in tasks.first { $0.title.hasPrefix(prefix) } }
            if let task = named ?? tasks.first(where: { $0.status == .inProgress }) ?? tasks.first { navigation.openTask(task.id) }
        case "taskflow": await taskFlow(workspace, navigation)
        case "session":
            // 打开 -CuePadSession（会话名，默认 homepage）的近况页，iPhone 在 Agent 标签里
            let title = defaults.string(forKey: "CuePadSession") ?? "homepage"
            guard let session = try? await workspace.services.store.piSessionPage(PiSessionQuery(text: title)).items.first(where: { $0.state.title == title })?.state else { break }
            if split { navigation.select(.agent) } else { navigation.tab = .agent }
            // -CuePadPushAfter <秒>：先停在 Agent 页，过一会儿再像点了会话行一样推入（录屏核对推入的首帧）
            let delay = defaults.double(forKey: "CuePadPushAfter")
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            navigation.openSession(session.id, sessionID: session.sessionID, store: workspace.services.store)
            if defaults.bool(forKey: "CuePadChatGrow") { Task { await growChat(session.sessionID, store: workspace.services.store) } }
            let bulk = defaults.integer(forKey: "CuePadChatBulk")
            if bulk > 0 { Task { await bulkChat(session.sessionID, count: bulk, store: workspace.services.store) } }
        case "sendflow":
            // 停在会话页 → 像点了发送一样写出请求（隔离模式没有同步、发送钮不可用）→ 返回 Agent 列表看状态流转；配 -CuePadDemoMac YES
            let title = defaults.string(forKey: "CuePadSession") ?? "notes"
            guard let session = try? await workspace.services.store.piSessionPage(PiSessionQuery(text: title)).items.first(where: { $0.state.title == title })?.state else { break }
            if split { navigation.select(.agent) } else { navigation.tab = .agent }
            navigation.openSession(session.id, sessionID: session.sessionID, store: workspace.services.store)
            try? await Task.sleep(for: .seconds(2))
            _ = try? await workspace.services.requestMacDelivery("看一下这周的待办", to: session, mode: .send)
            try? await Task.sleep(for: .seconds(0.4))
            if split { navigation.splitPath.removeLast() } else { navigation.agentPath.removeLast() }
        case "newsession":
            if split { navigation.select(.agent) } else { navigation.tab = .agent }
            var sheet = Navigation.NewSession(project: project)  // -CuePadProject 闲鱼：先选中还没绑文件夹的项目（头部引导选文件夹）
            if defaults.bool(forKey: "CuePadLaunch"),
               let table = try? await workspace.services.store.projects().first(where: { $0.name == "圆桌" })?.id {
                let token = UUID().uuidString
                if let request = try? await workspace.services.launch(
                    PiLaunch(project: table, prompt: "看看 scheduler 的重连问题", token: token), title: "圆桌", on: "demo-mac") {
                    sheet.launched = .init(request: request.id, token: token)
                }
            }
            navigation.newSession = sheet
        case "folderpicker":
            // 给 -CuePadProject（默认闲鱼，演示里没绑文件夹）选文件夹的候选页
            let name = defaults.string(forKey: "CuePadProject") ?? "闲鱼"
            workspace.folderPicker = try? await workspace.services.store.projects().first { $0.name == name }
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
            if let project { open(.project(project)) }
            navigation.startCapture()
        default:
            if let project, split { open(.project(project)) }
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

    /// search 画面里该不该激活这个范围的搜索：给了项目时只激活项目页的，否则只激活书架的。
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

extension DebugScene {
    fileprivate static func taskFlow(_ workspace: Workspace, _ navigation: Navigation) async {
        let store = workspace.services.store
        guard let table = try? await store.projects().first(where: { $0.name == "圆桌" }),
              let task = try? await store.createTask("补重连用例\n\n给 scheduler 补 3 个重连用例：第 6 位断线重连后仍排在原位。", in: table.id),
              let prompt = try? await store.children(of: task.id).first,
              let notes = try? await store.piSessionPage(PiSessionQuery(text: "notes")).items.first(where: { $0.state.title == "notes" })?.state
        else { return }
        try? await Task.sleep(for: .seconds(1.5))
        navigation.openTask(task.id)
        try? await Task.sleep(for: .seconds(2.5))
        _ = try? await workspace.services.requestMacDelivery(Outgoing.text(of: prompt), to: notes, mode: .send, card: prompt.id)
        navigation.task = nil
        try? await Task.sleep(for: .seconds(9))
        navigation.openTask(task.id)
        try? await Task.sleep(for: .seconds(2))
        try? await store.setStatus(task.id, .done)
        try? await Task.sleep(for: .seconds(1.5))
        navigation.task = nil
    }
}
#endif
