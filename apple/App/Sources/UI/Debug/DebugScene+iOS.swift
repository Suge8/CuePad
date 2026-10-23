#if os(iOS) && DEBUG
import CueStore
import CueSync
import SwiftUI
import UIKit

/// iOS 画面（`-CuePadScene`）：shelf（书架，窄屏底部的"项目"、宽屏侧栏的"全部项目"）、cue（Cue 页，iPad 侧栏展开；`-CuePadCuePanel YES` 页头一出现就展开成面板（`end` 再滚到面板底），`-CuePadPanelCycle YES` 就绪后反复开合；`-CuePadCuePresence disabled` 看说过话后停用时输入框上方那张启用的小纸（`CueWelcome`））、cuememory（再打开"Cue 记得什么"）、cuesettings（再推入 Cue 的设置）、project、older、editor、progress（进展页看板段，窄屏底部与宽屏侧栏的"进展"；给了 `-CuePadProject` 先把项目范围设成它）、sessions（进展页的会话段；给了 `-CuePadProject` 先把项目范围设成它，`-CuePadQuotaOpen YES` 顶栏胶囊长出额度明细）、send、search、trash、archive、settings、sidebar（iPad 展开侧栏）；不给是打开 App 的第一屏（Cue 页）。
/// search 是搜索页，出现即聚焦并填入 `-CuePadSearch`；`-CuePadSearchScope sessions` 打开在会话那一栏。
/// task 打开进行中第一条的任务气泡（没有落点、在上方居中；没有进行中的就是第一条待办；给了 `-CuePadTask <标题开头>` 是那一条）。
/// session：打开 `-CuePadSession <会话名>`（默认 homepage）的近况页（`-CuePadNotify YES`：走点锁屏通知的那条路进去；长对话与追加中的对话见 `DebugScene+LongChat.swift`）；send 是从卡片"发到 Mac"先选会话。
/// projectform：项目表单（给了 `-CuePadProject` 是编辑该项目，否则新建）。
/// style：视觉样板（`StyleBoard`）盖在最上层；icons：图标总览（`IconSheet`，iPad 竖屏一屏）。
/// widgets：小组件的小号与中号（`DebugWidgetStage`）；activity：实时活动的各态（`DebugActivityStage`）；share：分享扩展的表单（`DebugShareStage`）。都盖在最上层。
/// newsession：Agent 页上浮起新会话输入框；给了 `-CuePadLaunch YES` 则已经替你在圆桌发出（看送达中）。
/// `-CuePadDemoMac YES`：发给演示 Mac（demo-mac）上会话的话由它慢慢接手、送达、再回状态，对运行在它上面的 Cue 说的话也会交给 Cue（见 `runDemoMac`）。
/// `-CuePadCuePresence away`（cue 画面）：一夜里 Cue 陆续说了几句，回到 Cue 页从新消息读起；`-CuePadAwayAfter <秒>`：就绪后这么久离开 Cue 页、
/// 那几句这时才来，再回到 Cue 页，录"离开很久后回来"的定位（`awayIfAsked`）。
/// `-CuePadLiveActivity YES`：隔离库下也开真的实时活动（配 `-CuePadDemo YES`，演示库里有推进中与等你），验收锁屏与灵动岛；`simctl io screenshot` 拍不到灵动岛，录一小段取帧。
/// cuepanel：iPad 在项目页旁开着右侧 Cue 面板。演示库另写入 Mac 同步来的 Pi 会话状态（含历史）与几条发到 Mac 的请求。
extension DebugScene {
    /// 模拟器当作接了电脑键盘、聚焦不弹软键盘：清掉输入法的硬件键盘布局后照常弹出（私有选择子，只在 Debug 里）。
    private static func showSoftwareKeyboard() {
        let selector = NSSelectorFromString("setHardwareLayout:")
        for mode in UITextInputMode.activeInputModes where mode.responds(to: selector) { mode.perform(selector, with: nil) }
    }

    static func prepare(_ workspace: Workspace) async {
        if defaults.string(forKey: "CuePadBench") == "interact" { IOSInteractionBench.beginCold() }
        dumpAccessibilityIfAsked()
        if defaults.bool(forKey: "CuePadSoftKeyboard") { showSoftwareKeyboard() }
        if defaults.bool(forKey: "CuePadLandscape") {
            (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
        }
        let project = await prepareLibrary(workspace)
        if defaults.bool(forKey: "CuePadDemo") { await seedRemote(workspace.services) }
        if defaults.bool(forKey: "CuePadDemoMac") { Task { await runDemoMac(workspace.services) } }
        if defaults.bool(forKey: "CuePadNoAsks") { await settleAsks(workspace.services.store) }
        if defaults.string(forKey: "CuePadBench") == "interact" {
            Task { await IOSInteractionBench.run(workspace) }
            return
        }
        func open(_ route: Route) { workspace.select(route) }
        func openCard() async {
            if let project { open(.project(project)) }
            if let card = await card(in: project ?? Project.defaultID, store: workspace.services.store) { workspace.push(.card(card)) }
        }
        switch scene {
        case "shelf": open(.shelf)
        case "project", "older": if let project { open(.project(project)) }
        case "projectform":
            // 给了项目是编辑它，否则新建
            let existing = if let project { try? await workspace.services.store.project(project) } else { Project?.none }
            workspace.projectForm = .init(project: existing)
        case "sidebar":
            if let project { open(.project(project)) }
            workspace.sidebar = .all
        case "trash": open(.trash)
        case "archive": open(.archive)
        case "settings": open(.settings)
        case "editor": await openCard()
        case "send":
            await openCard()
            if let id = await card(in: project ?? Project.defaultID, store: workspace.services.store),
               let card = try? await workspace.services.store.card(id) {
                let outbox = Outbox(content: Outgoing.text(of: card), card: id, project: project)
                // 给了 -CuePadSession 就当已选好会话，直接进它的近况页（卡片预填在回复框里）
                if let title = defaults.string(forKey: "CuePadSession"),
                   let session = try? await workspace.services.store.piSessionPage(PiSessionQuery(text: title)).items.first(where: { $0.state.title == title })?.state {
                    let settings = workspace.services.settings
                    var reply = settings.replyDraft(for: session.id)
                    reply.attachments = [outbox]
                    settings.setReplyDraft(reply, for: session.id)
                    workspace.openSession(session.id, sessionID: session.sessionID)
                } else {
                    workspace.outbox = outbox
                }
            }
        case "cue", "cuememory", "cuesettings":
            // 一夜里来的话要在不看 Cue 页时写（看着时写当场就读掉了）：先离开、写完再回来，才是"回来时有新消息"的样子
            if defaults.string(forKey: "CuePadCuePresence") == "away" {
                workspace.show(.progress)
                await NextFrame.wait()
            }
            if defaults.bool(forKey: "CuePadDemo") { await seedCue(workspace.services) }
            if let draft = defaults.string(forKey: "CuePadCueDraft") { workspace.cue.draft.text = draft }
            workspace.show(.cue)
            if defaults.bool(forKey: "CuePadPlacesOpen") { openPlaces() }
            workspace.sidebar = .all
            if scene == "cuememory" { workspace.cue.showsMemory = true }
            if scene == "cuesettings" { workspace.push(.cueSettings) }
            if defaults.bool(forKey: "CuePadPanelCycle") { Task { await cyclePanel() } }
        case "cuepanel":
            if defaults.bool(forKey: "CuePadDemo") { await seedCue(workspace.services) }
            open(project.map(Route.project) ?? .shelf)
            workspace.agentPanel = true
        case "cuerows":
            await seedCueRows(workspace.services)
            workspace.showSessions()
        case "progress":
            // 看板的等你列：配 -CuePadDemo 时写入 Cue 的等你（会话在问的随演示 Mac 的会话来）
            if defaults.bool(forKey: "CuePadDemo") {
                await seedCue(workspace.services)
                await seedBusyBoard(workspace.services.store)
            }
            await seedCanvasSteps(workspace.services.store)
            workspace.projectScope = project
            workspace.show(.progress)
        case "task":
            let store = workspace.services.store
            let tasks = (try? await store.tasks(.inProgress, .todo).flatMap(\.tasks)) ?? []
            // 给了 -CuePadTask <标题开头> 打开那一条，否则进行中的第一条
            let named = defaults.string(forKey: "CuePadTask").flatMap { prefix in tasks.first { $0.title.hasPrefix(prefix) } }
            if let task = named ?? tasks.first(where: { $0.status == .inProgress }) ?? tasks.first { workspace.openTask(task) }
        case "session":
            // 打开 -CuePadSession（会话名，默认 homepage）的近况页，推在 Agent 整页上
            let title = defaults.string(forKey: "CuePadSession") ?? "homepage"
            if defaults.bool(forKey: "CuePadDemo") { await seedCue(workspace.services) }
            guard let session = try? await workspace.services.store.piSessionPage(PiSessionQuery(text: title)).items.first(where: { $0.state.title == title })?.state else { break }
            if defaults.bool(forKey: "CuePadNotify") {
                workspace.open(DeepLink.session(session.id))  // 点锁屏通知进来：只带记录 id
            } else {
                workspace.showSessions()
                workspace.openSession(session.id, sessionID: session.sessionID)
            }
            if defaults.bool(forKey: "CuePadStream") { Task { await stream(session.sessionID, store: workspace.services.store) } }
        case "newsession":
            workspace.showSessions()
            var sheet = NewSessionInput.Start(project: project)  // -CuePadProject 闲鱼：先选中还没绑文件夹的项目（交给 Cue 那台 Mac 建工作区）
            if defaults.bool(forKey: "CuePadLaunch"),
               let table = try? await workspace.services.store.projects().first(where: { $0.name == "圆桌" })?.id {
                sheet.launched = try? await workspace.services.launchSession(
                    in: table, prompt: "看看 scheduler 的重连问题", title: "圆桌", on: "demo-mac", card: nil, agent: .pi)
            }
            workspace.newSession = sheet
        case "folderpicker":
            // 给 -CuePadProject（默认闲鱼，演示里没绑文件夹）选文件夹的候选页
            let name = defaults.string(forKey: "CuePadProject") ?? "闲鱼"
            workspace.folderPicker = try? await workspace.services.store.projects().first { $0.name == name }
        case "sessions":
            workspace.projectScope = project
            workspace.showSessions()
        case "search":
            workspace.openSearch()
        default: break
        }
        await presetSpeech(workspace)
    }

    /// `-CuePadAlertStatus <on|pending|denied|undetermined|registerFailed|subscribeFailed>`：设置页通知那一行按这个状态显示
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

    /// `-CuePadDockTour YES`（iPhone，配 `-CuePadDemo YES`）：画面就绪后每一拍走一步，每步走点按调的那条路：Cue 页展开"⋯" → 去任务 →
    /// 去会话 → 推入一个会话 → 返回 → 去项目 → 推入搜索 → 返回 → 推入一个会话再换去任务（推入的页清掉）→ 回 Cue →
    /// 不经"⋯"直接去会话（快捷键、通知的那条路）→ 回 Cue → 直接去项目 → 去会话（隔一格）→ 回 Cue → 聚焦输入框（"⋯"让开）。
    static func dockTourIfAsked(_ workspace: Workspace) async {
        guard defaults.bool(forKey: "CuePadDockTour") else { return }
        let sessions = ((try? await workspace.services.store.piSessionPage(PiSessionQuery(limit: 2)))?.items ?? []).map(\.state)
        // 节奏是要录的内容，不是在等别的事
        func beat() async { try? await Task.sleep(for: .seconds(1.6)) }
        func open(_ index: Int) {
            guard sessions.indices.contains(index) else { return }
            workspace.openSession(sessions[index].id, sessionID: sessions[index].sessionID)
        }
        await beat()
        openPlaces()
        await beat()
        workspace.select(.progress)
        await beat()
        workspace.showSessions()
        await beat()
        open(0)
        await beat()
        workspace.path.removeAll()
        await beat()
        workspace.select(.shelf)
        await beat()
        workspace.openSearch()
        await beat()
        workspace.closeSearch()
        await beat()
        open(1)
        await beat()
        workspace.select(.progress)
        await beat()
        workspace.select(.cue)
        await beat()
        workspace.showSessions()
        await beat()
        workspace.select(.cue)
        await beat()
        workspace.select(.shelf)
        await beat()
        workspace.showSessions()
        await beat()
        workspace.select(.cue)
        await beat()
        workspace.speakToCue()
    }

    /// `-CuePadPanelCycle YES`（配 cue 画面录屏）：画面就绪后每 1.5 秒点一下 Cue 页头，开合面板几遍，看动效。
    private static func cyclePanel() async {
        try? await Task.sleep(for: .seconds(4))
        for _ in 0..<8 {
            toggleCuePanel()
            try? await Task.sleep(for: .seconds(1.5))
        }
    }
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
