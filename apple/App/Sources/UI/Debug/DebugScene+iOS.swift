#if os(iOS) && DEBUG
import CueStore
import CueSync
import SwiftUI
import UIKit

/// iOS 画面（`-CuePadScene`）：shelf（书架，窄屏侧栏与宽屏主区的"项目"）、cue（Cue 页，宽屏会话条展开；`-CuePadCuePanel YES` 页头一出现就展开成面板，`-CuePadPanelCycle YES` 就绪后反复开合；`-CuePadCuePresence disabled` 看说过话后停用时输入框上方那张启用的小纸（`CueWelcome`））、cuememory（再打开"Cue 记得什么"）、cueschedules（再打开定时）、project、older、editor、progress（进展的看板，窄屏侧栏与宽屏主区的"进展"；给了 `-CuePadProject` 先把项目范围设成它，`-CuePadQuotaOpen YES` 额度明细一出现就长开）、sessions（搜索页的会话一栏：在线的与历史的会话行）、earlier（"更早"那一页，已结束的会话）、send、search、trash、archive、settings（配 -CuePadDemo 时 Cue 运行在演示的 Mac 上）、sidebar（窄屏开着侧栏、宽屏会话条展开；给了 `-CuePadProject` 先打开那个项目）；不给是打开 App 的第一屏（Cue 页）。
/// search 是搜索页，出现即聚焦并填入 `-CuePadSearch`；`-CuePadSearchScope sessions` 打开在会话那一栏。
/// library 是技能与规则（`-CuePadLibraryTab skills` 打开在技能那一段），再推入文件页：instruction 是全局规则（给了 `-CuePadProject` 是那个项目的，
/// 演示的全局规则顶上有合并那一条，`-CuePadMergePreview YES` 已点过一下"合并进来"、标出会并进来的段），skill 是 write-swift，duplicate 是同名的 release。
/// more 打开进行中第一条的"更多"气泡（任务行左滑那一下，没有落点）。`-CuePadTurnCycle YES` 配 more、task、search：就绪后来回翻页、换范围（`debugCyclesTurn`）。
/// task 打开进行中第一条的任务气泡（没有落点、在上方居中；没有进行中的就是第一条待办；给了 `-CuePadTask <标题开头>` 是那一条）。
/// session：打开 `-CuePadSession <会话名>`（默认 homepage）的会话页（`-CuePadNotify YES`：走点锁屏通知的那条路进去；长对话与追加中的对话见 `DebugScene+LongChat.swift`）；send 是从卡片"发到 Mac"先选会话。
/// projectform：项目表单（给了 `-CuePadProject` 是编辑该项目，否则新建）。
/// style：视觉样板（`StyleBoard`）盖在最上层；icons：图标总览（`IconSheet`，iPad 竖屏一屏）；stateicons：状态图形总览（`StateGlyphSheet`，一列往下滚，Mac 也有）。
/// widgets：小组件的小号与中号（`DebugWidgetStage`）；activity：实时活动的各态（`DebugActivityStage`）；share：分享扩展的表单（`DebugShareStage`）。都盖在最上层。
/// newsession：进展的看板上浮起新会话输入框；给了 `-CuePadLaunch YES` 则已经替你在圆桌发出（看送达中）。
/// `-CuePadDemoMac YES`：发给演示 Mac（demo-mac）上会话的话由它慢慢接手、送达、再回状态，对运行在它上面的 Cue 说的话也会交给 Cue（见 `runDemoMac`）。
/// `-CuePadCuePresence away`（cue 画面）：一夜里 Cue 陆续说了几句，回到 Cue 页从新消息读起；`-CuePadAwayAfter <秒>`：就绪后这么久离开 Cue 页、
/// 那几句这时才来，再回到 Cue 页，录"离开很久后回来"的定位（`awayIfAsked`）。
/// `-CuePadLiveActivity YES`：隔离库下也开真的实时活动（配 `-CuePadDemo YES`，演示库里有推进中与等你），验收锁屏与灵动岛；`simctl io screenshot` 拍不到灵动岛，录一小段取帧。
/// cuepanel：宽屏主区开着项目页、右栏是 Cue。演示库另写入 Mac 同步来的 Pi 会话状态（含历史）与几条发到 Mac 的请求。
extension DebugScene {
    /// 模拟器当作接了电脑键盘、聚焦不弹软键盘：清掉输入法的硬件键盘布局后照常弹出（私有选择子，只在 Debug 里）。
    private static func showSoftwareKeyboard() {
        let selector = NSSelectorFromString("setHardwareLayout:")
        for mode in UITextInputMode.activeInputModes where mode.responds(to: selector) { mode.perform(selector, with: nil) }
    }

    /// iPad 的窗口模式下系统记着上次的窗口大小（别的调试会话缩过、拖过的窗口下次照那么大起）：调试实例铺满屏，截图、录屏画的是整屏的四列；
    /// 要窄窗口用 `-CuePadCompact`。只撑最小尺寸、不锁死：起来后照样能拖小。
    private static func fillScreenOnPad() {
        guard UIDevice.current.userInterfaceIdiom == .pad, defaults.string(forKey: "CuePadCompact") == nil,
              let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene, let restrictions = scene.sizeRestrictions
        else { return }
        restrictions.minimumSize = scene.screen.bounds.size
        Task {
            await NextFrame.wait()
            restrictions.minimumSize = .zero
        }
    }

    static func prepare(_ workspace: Workspace) async {
        if defaults.string(forKey: "CuePadBench") == "interact" { IOSInteractionBench.beginCold() }
        dumpAccessibilityIfAsked()
        logAccessibilityFocusIfAsked()
        if defaults.bool(forKey: "CuePadSoftKeyboard") { showSoftwareKeyboard() }
        fillScreenOnPad()
        let project = await prepareLibrary(workspace)
        if defaults.bool(forKey: "CuePadDemo") {
            await seedRemote(workspace.services)
            // Cue 在演示 Mac 上值班才有"等 Cue 回答"与待回复：每个画面都写（已写过就不再写）；Cue 页那几档在摆画面时按各自的先后写
            if !["cue", "cuememory", "cueschedules"].contains(scene ?? "") { await seedCue(workspace.services) }
        }
        if defaults.bool(forKey: "CuePadDemoMac") { Task { await runDemoMac(workspace.services) } }
        if defaults.bool(forKey: "CuePadNoAsks") { await settleAsks(workspace.services.store) }
        await IslandBench.run(workspace.services)  // 跑完才报就绪：xc.sh run 一直持有这台模拟器，别的任务换不掉它
        if defaults.string(forKey: "CuePadBench") == "interact" {
            Task { await IOSInteractionBench.run(workspace) }
            return
        }
        presetColumns(workspace.services.settings)
        await running("摆画面") { try await presetScene(workspace, project: project) }
        presetDrawers(workspace)
        await presetSpeech(workspace)
        await prepareNarrow(workspace)
        if let pace = defaults.string(forKey: "CuePadSidebarCycle") { Task { await cycleWide(fast: pace == "fast") { workspace.railExpanded.toggle() } } }
        if let pace = defaults.string(forKey: "CuePadRightCycle") { Task { await cycleWide(fast: pace == "fast") { workspace.services.settings.cueOpen.toggle() } } }
    }

    /// `-CuePadSidebarCycle`、`-CuePadRightCycle`（iPad 宽屏，配录屏）：同 Mac，反复开合会话条或 Cue（直接改用户的开合选择，同侧栏钮与 Cue 钮），`fast` 在动画中途反向。
    private static func cycleWide(fast: Bool, _ toggle: () -> Void) async {
        // 两次之间停多久是录屏的节奏，不是在等别的事
        let gaps: [Double] = fast ? [0.1, 1.5, 0.06, 0.06, 1.5] : [1.5]
        await Task.wait(for: .seconds(3))
        var step = 0
        while !Task.isCancelled {
            toggle()
            await Task.wait(for: .seconds(gaps[step % gaps.count]))
            step += 1
        }
    }

    private static func presetScene(_ workspace: Workspace, project: UUID?) async throws {
        func open(_ route: Route) { workspace.select(route) }
        func openCard() async throws {
            if let project { open(.project(project)) }
            if let card = try await card(in: project ?? Project.defaultID, store: workspace.services.store) { workspace.push(.card(card)) }
        }
        switch scene {
        case "shelf": open(.shelf)
        case "project", "older": if let project { open(.project(project)) }
        case "projectform":
            // 给了项目是编辑它，否则新建
            let existing = if let project { try await workspace.services.store.project(project) } else { Project?.none }
            workspace.projectForm = .init(project: existing)
        case "sidebar":
            if let project { open(.project(project)) }
            workspace.sidebarOpen = true
        case "trash": open(.trash)
        case "archive": open(.archive)
        case "library", "instruction", "skill", "duplicate":
            // 同 Mac
            if defaults.bool(forKey: "CuePadDemo") { await seedCue(workspace.services) }
            open(.library)
            workspace.libraryPane = DebugHooks.preset.libraryPane
            if let scene, let file = DemoAgentLibrary.file(scene: scene, project: project) { workspace.openLibrary(file) }
        case "settings":
            // 配演示库时 Cue 运行在演示的 Mac Studio 上（同 Mac 的设置画面）
            if defaults.bool(forKey: "CuePadDemo") { await seedCue(workspace.services) }
            open(.settings)
        case "editor": try await openCard()
        case "send":
            try await openCard()
            if let id = try await card(in: project ?? Project.defaultID, store: workspace.services.store),
               let card = try await workspace.services.store.card(id) {
                let outbox = Outbox(content: Outgoing.text(of: card), card: id, project: project)
                // 给了 -CuePadSession 就当已选好会话，直接进它的近况页（卡片预填在回复框里）
                if let title = defaults.string(forKey: "CuePadSession"), let session = try await demoSession(titled: title, store: workspace.services.store) {
                    let settings = workspace.services.settings
                    var reply = settings.replyDraft(for: session.id)
                    reply.attachments = [outbox]
                    settings.setReplyDraft(reply, for: session.id)
                    workspace.openSession(session.id, sessionID: session.sessionID)
                } else {
                    workspace.outbox = outbox
                }
            }
        case "cue", "cuememory", "cueschedules":
            // 一夜里来的话要在不看 Cue 页时写（看着时写当场就读掉了）：先离开、写完再回来，才是"回来时有新消息"的样子
            if defaults.string(forKey: "CuePadCuePresence") == "away" {
                workspace.show(.progress)
                await NextFrame.wait()
            }
            if defaults.bool(forKey: "CuePadDemo") { await seedCue(workspace.services) }
            if let draft = defaults.string(forKey: "CuePadCueDraft") { workspace.cue.draft.text = draft }
            workspace.show(.cue)
            if workspace.layout == .wide { workspace.sidebarOpen = true }
            if scene == "cuememory" { workspace.cue.showsMemory = true } else { workspace.cue.showsSchedules = scene == "cueschedules" }
            if defaults.bool(forKey: "CuePadPanelCycle") { Task { await cyclePanel() } }
        case "cuepanel":
            if defaults.bool(forKey: "CuePadDemo") { await seedCue(workspace.services) }
            open(project.map(Route.project) ?? .shelf)
            workspace.show(.cue)
        case "cuerows":
            await seedCueRows(workspace.services)
            workspace.openSearch()
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
            // 没给 -CuePadTask 时是进行中的第一条
            await openTask(workspace) { $0.status == .inProgress }
        case "more":
            // 任务行左滑"⋯ 更多"长出的气泡（同 `CardActions` 里那一下），进行中的第一条
            if let task = try await workspace.services.store.tasks(.inProgress, .todo).flatMap(\.tasks).first {
                workspace.moreCard = CardMoreRequest(card: task, opens: false, source: .unanchored)
            }
        case "session":
            // 打开 -CuePadSession（会话名，默认 homepage）的会话页
            let title = defaults.string(forKey: "CuePadSession") ?? "homepage"
            if defaults.bool(forKey: "CuePadDemo") { await seedCue(workspace.services) }
            guard let session = try await demoSession(titled: title, store: workspace.services.store) else { break }
            if defaults.bool(forKey: "CuePadNotify") {
                workspace.open(DeepLink.session(session.id))  // 点锁屏通知进来：只带记录 id
            } else {
                workspace.openSession(session.id, sessionID: session.sessionID)
            }
            if defaults.bool(forKey: "CuePadStream") { Task { await stream(session.sessionID, store: workspace.services.store) } }
        case "newsession":
            workspace.show(.progress)
            var sheet = NewSessionInput.Start(project: project)  // -CuePadProject 闲鱼：先选中还没绑文件夹的项目（交给 Cue 那台 Mac 建工作区）
            if defaults.bool(forKey: "CuePadLaunch"),
               let table = try await workspace.services.store.projects().first(where: { $0.name == String(localized: "圆桌", table: "Demo") })?.id {
                sheet.launched = try await workspace.services.launchSession(
                    in: table, prompt: String(localized: "看看 scheduler 的重连问题", table: "Demo"), title: String(localized: "圆桌", table: "Demo"), on: "demo-mac", card: nil, agent: .pi)
            }
            workspace.newSession = sheet
        case "folderpicker":
            // 给 -CuePadProject（默认闲鱼，演示里没绑文件夹）选文件夹的候选页
            let name = defaults.string(forKey: "CuePadProject") ?? String(localized: "闲鱼", table: "Demo")
            workspace.folderPicker = try await workspace.services.store.projects().first { $0.name == name }
        case "sessions":
            // 配 -CuePadDemo 时 Cue 在演示 Mac 上值班（同 Mac 的 sessions）：会话行按值班时的样子写（歇着、等 Cue 回答、待回复）
            if defaults.bool(forKey: "CuePadDemo") { await seedCue(workspace.services) }
            workspace.openSearch()
        case "earlier":
            if defaults.bool(forKey: "CuePadDemo") { await seedCue(workspace.services) }
            workspace.push(.earlier)
        case "search":
            workspace.openSearch()
        default: break
        }
    }

    /// 演示会话按会话名找（演示会话的会话名各不相同）。
    private static func demoSession(titled title: String, store: CueStore) async throws -> PiSessionState? {
        try await store.piSessionPage(PiSessionQuery(text: title)).items.first { $0.state.title == title }?.state
    }

    /// `-CuePadAlertStatus <on|pending|denied|undetermined|registerFailed|subscribeFailed>`：设置页通知那一行按这个状态显示
    /// （演示模式没有同步、真实状态出不来）。
    static var alertStatus: PiAlertStatus? {
        switch defaults.string(forKey: "CuePadAlertStatus") {
        case "on": PiAlertStatus(authorization: .authorized, registration: .registered, subscription: .active)
        case "pending": PiAlertStatus(authorization: .authorized, registration: .pending, subscription: .off)
        case "denied": PiAlertStatus(authorization: .denied, registration: .pending, subscription: .off)
        case "undetermined": PiAlertStatus(authorization: .notDetermined, registration: .pending, subscription: .off)
        case "registerFailed": PiAlertStatus(authorization: .authorized, registration: .failed(String(localized: "没有连接到 Apple 推送服务", table: "Demo")), subscription: .off)
        case "subscribeFailed": PiAlertStatus(authorization: .authorized, registration: .registered, subscription: .failed(String(localized: "iCloud 账号不可用", table: "Demo")))
        default: nil
        }
    }

    /// `-CuePadPanelCycle YES`（配 cue 画面录屏）：画面就绪后每 1.5 秒点一下 Cue 页头，开合面板几遍，看动效。
    private static func cyclePanel() async {
        await Task.wait(for: .seconds(4))
        for _ in 0..<8 {
            toggleCuePanel()
            await Task.wait(for: .seconds(1.5))
        }
    }
}
#endif

