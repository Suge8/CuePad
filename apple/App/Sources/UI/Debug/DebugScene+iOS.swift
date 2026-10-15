#if os(iOS) && DEBUG
import CueStore
import CueSync
import SwiftUI
import UIKit

/// iOS 画面（`-CuePadScene`）：shelf（书架）、cue（Cue 标签；iPad 侧栏的 Cue，侧栏展开；`-CuePadCuePanel YES` 页头一出现就展开成面板，`-CuePadPanelCycle YES` 就绪后反复开合）、cuememory（再打开"Cue 记得什么"）、project、older、unfiled、editor、attach（editor 再弹出"挂到任务"面板）、tasks、agent（Agent 整页，iPhone 推在 Cue 标签里）、send、search、trash、archive、settings、sidebar（iPad 展开侧栏）；不给是打开 App 的第一屏（iPhone 是 Cue 标签）。
/// search 是搜索页（iPhone 的搜索标签），出现即聚焦并填入 `-CuePadSearch`；`-CuePadSearchScope sessions` 打开在会话那一栏。
/// task 在书架上推入"正在推进"第一条的任务页（没有就是第一条待办；给了 `-CuePadTask <标题开头>` 是那一条）。
/// session：打开 `-CuePadSession <会话名>`（默认 homepage）的近况页（`-CuePadNotify YES`：走点锁屏通知的那条路进去；长对话与追加中的对话见 `DebugScene+LongChat.swift`）；send 是从卡片"发到 Mac"先选会话。
/// projectform：项目表单（给了 `-CuePadProject` 是编辑该项目，否则新建）。
/// projectagent：在 `-CuePadProject` 的项目页上推入它的 Agent 页（筛着这个项目）。
/// style：视觉样板（`StyleBoard`）盖在最上层。
/// newsession：Agent 页上浮起新会话输入框；给了 `-CuePadLaunch YES` 则已经替你在圆桌发出（看送达中）。
/// `-CuePadDemoMac YES`：发给演示 Mac（demo-mac）上会话的话由它慢慢接手、送达、再回状态，对住在它上面的 Cue 说的话也会交给 Cue（见 `runDemoMac`）。
/// cuepanel：iPad 在项目页旁开着右侧 Cue 面板。演示库另写入 Mac 同步来的 Pi 会话状态（含历史）与几条发到 Mac 的请求。
extension DebugScene {
    static func prepare(_ workspace: Workspace, _ navigation: Navigation) async {
        dumpAccessibilityIfAsked()
        let project = await prepareLibrary(workspace)
        if defaults.bool(forKey: "CuePadDemo") { await seedRemote(workspace.services) }
        if defaults.bool(forKey: "CuePadDemoMac") { Task { await runDemoMac(workspace.services) } }
        if defaults.string(forKey: "CuePadBench") == "interact" {
            Task { await IOSInteractionBench.run(workspace, navigation) }
            return
        }
        let split = navigation.layout == .split
        func open(_ route: Route) {
            if split { navigation.select(route) } else { navigation.tab = .projects; navigation.projectsPath = [route] }
        }
        func openCard() async {
            if let project { open(.project(project)) }
            if let card = await card(in: project, store: workspace.services.store) { navigation.push(.card(card)) }
        }
        switch scene {
        case "shelf": if !split { navigation.tab = .projects }
        case "project", "older": if let project { open(.project(project)) }
        case "projectform":
            // 给了项目是编辑它，否则新建
            let existing = if let project { try? await workspace.services.store.project(project) } else { Project?.none }
            navigation.projectForm = .init(project: existing)
        case "sidebar":
            if let project { open(.project(project)) }
            navigation.sidebar = .all
        case "unfiled": open(.unfiled)
        case "trash": open(.trash)
        case "archive": open(.archive)
        case "settings": open(.settings)
        case "editor": await openCard()
        case "attach":
            await openCard()
            try? await Task.sleep(for: .seconds(1))
            if let id = await card(in: project, store: workspace.services.store) { workspace.attaching = try? await workspace.services.store.card(id) }
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
        case "cue", "cuememory":
            if defaults.bool(forKey: "CuePadDemo") { await seedCue(workspace.services) }
            navigation.show(.cue)
            if split { navigation.sidebar = .all }
            if scene == "cuememory" { workspace.cue.showsMemory = true }
            if defaults.bool(forKey: "CuePadPanelCycle") { Task { await cyclePanel() } }
        case "cuepanel":
            if defaults.bool(forKey: "CuePadDemo") { await seedCue(workspace.services) }
            if let project { open(.project(project)) }
            navigation.agentPanel = true
        case "cuerows":
            await seedCueRows(workspace.services)
            navigation.show(.agent)
        case "tasks":
            navigation.show(.tasks)
        case "task":
            let store = workspace.services.store
            let tasks = (try? await store.tasks(.inProgress, .todo).flatMap(\.tasks)) ?? []
            // 给了 -CuePadTask <标题开头> 打开那一条，否则进行中的第一条
            let named = defaults.string(forKey: "CuePadTask").flatMap { prefix in tasks.first { $0.title.hasPrefix(prefix) } }
            if let task = named ?? tasks.first(where: { $0.status == .inProgress }) ?? tasks.first { open(.card(task.id)) }
        case "session":
            // 打开 -CuePadSession（会话名，默认 homepage）的近况页，iPhone 推在 Cue 标签的 Agent 整页上
            let title = defaults.string(forKey: "CuePadSession") ?? "homepage"
            if defaults.bool(forKey: "CuePadDemo") { await seedCue(workspace.services) }
            guard let session = try? await workspace.services.store.piSessionPage(PiSessionQuery(text: title)).items.first(where: { $0.state.title == title })?.state else { break }
            if defaults.bool(forKey: "CuePadNotify") {
                navigation.open(alert: PiAlertTap(kind: .settled, sessionState: session.id))  // 点锁屏通知进来：只带记录 id、没有首帧
            } else {
                navigation.show(.agent)
                navigation.openSession(session.id, sessionID: session.sessionID, store: workspace.services.store)
            }
            if defaults.bool(forKey: "CuePadStream") { Task { await stream(session.sessionID, store: workspace.services.store) } }
            if defaults.string(forKey: "CuePadBench") == "chatdepth" { Task { await ChatDepthBench.run() } }
        case "newsession":
            navigation.show(.agent)
            var sheet = Navigation.NewSession(project: project)  // -CuePadProject 闲鱼：先选中还没绑文件夹的项目（头部引导选文件夹）
            if defaults.bool(forKey: "CuePadLaunch"),
               let table = try? await workspace.services.store.projects().first(where: { $0.name == "圆桌" })?.id {
                let token = UUID().uuidString
                if let request = try? await workspace.services.launch(
                    PiLaunch(project: table, prompt: "看看 scheduler 的重连问题", token: token), title: "圆桌", on: "demo-mac") {
                    sheet.launched = .init(request: request.id, token: token)
                }
            }
            navigation.startNewSession(sheet, hasProjects: workspace.catalog?.projects.isEmpty == false)
        case "folderpicker":
            // 给 -CuePadProject（默认闲鱼，演示里没绑文件夹）选文件夹的候选页
            let name = defaults.string(forKey: "CuePadProject") ?? "闲鱼"
            workspace.folderPicker = try? await workspace.services.store.projects().first { $0.name == name }
        case "projectagent":
            // 从项目页的"全部 N 个会话"进来的 Agent 页：先筛着这个项目
            if let project { open(.project(project)); navigation.push(.projectSessions(project)) }
        case "agent":
            if let project { open(.project(project)) }
            navigation.show(.agent)
        case "search":
            navigation.openSearch()
        default:
            if let project, split { open(.project(project)) }
        }
        await presetSpeech(workspace)
    }

    /// `-CuePadAlertStatus <on|pending|denied|undetermined|registerFailed|subscribeFailed>`：设置页"Pi 通知"一行按这个状态显示
    /// （演示模式没有同步、真实状态出不来）。
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

    /// `-CuePadPanelCycle YES`（配 cue 画面录屏）：画面就绪后每 1.5 秒点一下 Cue 页头，开合面板几遍，看动效。
    private static func cyclePanel() async {
        try? await Task.sleep(for: .seconds(4))
        for _ in 0..<8 {
            toggleCuePanel()
            try? await Task.sleep(for: .seconds(1.5))
        }
    }

    /// 底部栏换标签的那条路（`debugExposesTabSelect`）。
    static var selectTab: (Navigation.Tab) -> Void = { _ in }
}
#endif

#if os(iOS) && DEBUG
import UIKit

/// `-CuePadAXDump YES`：界面起来 4 秒后把读屏看到的元素（标签、值、特征）按顺序写进资料库目录的
/// `ax-dump.txt`（行末是元素尺寸），给没有 UI 测试目标、没有 Simulator 图形界面时核对无障碍。自动化模式下 `accessibilityHidden` 的元素也会列出，
/// 所以多于读屏真读的；合并元素的标签（分隔点、图标名有没有混进去）才是读屏读到的。
extension DebugScene {
    static func dumpAccessibilityIfAsked() {
        guard defaults.bool(forKey: "CuePadAXDump"), let dir = ProcessInfo.processInfo.environment["CUEPAD_LIBRARY_DIR"] else { return }
        // 和 XCTest 一样打开"自动化"无障碍：SwiftUI 只在有辅助技术时才建出元素树
        if let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let symbol = dlsym(handle, "_AXSSetAutomationEnabled") {
            unsafeBitCast(symbol, to: (@convention(c) (Int32) -> Void).self)(1)
        }
        Task {
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
            let size = node.accessibilityFrame.size
            lines.append("\(kind) '\(node.accessibilityLabel ?? "")'\(value) [\(Int(size.width))×\(Int(size.height))]")
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
