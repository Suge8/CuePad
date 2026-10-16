import CueStore
import SwiftUI

/// 滚动定位锚点。
enum ScrollAnchor {
    static let older = "older"
}

#if DEBUG
/// 视觉验收用的启动参数（只在 Debug 构建读取，配合 `CUEPAD_LIBRARY_DIR` 使用隔离资料库）：
/// - `-CuePadDemo YES`：库为空时写入演示数据；
/// - `-CuePadSeed perf`（仅 Mac）：库为空时写入性能测量用的大资料库（`PerfLibrary`），配合 `-CuePadBench interact`；
/// - `-CuePadProject <名称>`：打开该项目；
/// - `-CuePadScene <画面>`：初始画面。Mac：collapsed、older、editor（-CuePadCard 那张散放的灵感进编辑页）、task（在任务浮窗里打开本项目第一条任务；给了 `-CuePadTask <标题开头>` 是那一条）、search、tasks、agentsetup（接入 Agent 的面板）、connected（几家 Agent 接进隔离目录、打开 Agent 页：看接入后的侧栏与 + 的新会话里选 Agent）、select（批量选择本页前三条灵感）、trash、archive、settings（拍真的设置窗口，主窗口收起）、menubar、cuebar（"对 Cue 说"的输入条）、projectform；
///   cue 打开 Cue 页、cuememory 再打开"Cue 记得什么"、cuerun 再打开"运行情况"（仅 Mac，Cue 在这台值班时才有；演示数据见 `DebugScene+Cue.swift`）；
///   agent 打开 Agent 整页列表，session 整页打开 `-CuePadSession <会话名>`（这两个画面配 `-CuePadDemo YES` 时写入 Mac 同步来的演示会话，见 `DebugScene+PiDemo.swift`；notes 里你的话带一张图、relay 里发出还没进对话的话带一张图，核对对话里的图片；长对话与追加中的对话见 `DebugScene+LongChat.swift`）；
///   iOS 见 `DebugScene+iOS.swift`；
/// - `-CuePadSearch <关键词>`：search 画面的预填关键词；`-CuePadCard <正文开头>`：editor 画面打开哪张卡；`-CuePadSelect <起点:长度>`：编辑器载入后选中这一段（看选区操作）；
/// - `-CuePadWindowSize 1280x800`（仅 Mac）：主窗口尺寸（内容铺满标题栏，即整窗尺寸）；`-CuePadSidebar hidden`（仅 Mac）：任何画面都先收起侧栏；
/// - `-CuePadBench <interact|churn|chatdepth>`（量完退出）：interact 是单次交互的点击回合与掉帧，与交互预算比较（Mac 见 `InteractionBench`，iOS 见 `IOSInteractionBench`，`-CuePadInteractOnly 项,项` 只量列出的几项）；
///   chatdepth（仅 iOS）是长对话从最新处一路往上翻到第 1 轮、每排开一段的开销（`ChatDepthBench`，见 `DebugScene+LongChat.swift`）；
///   chatresize（仅 Mac，不退出）是长对话翻到深处后每次拖窗口边改宽的开销（`ChatResizeBench`，同一文件）；
///   chatscroll（仅 Mac，量完退出）是长对话里滚动的每圈主线程 CPU、指令数与掉帧（`ChatScrollBench`，同一文件；`-CuePadScrollDriver`、`-CuePadScrollPointer` 与方法限制见它的注释）；
///   churn（仅 Mac）边加卡边逐点拉宽窗口，查布局反馈环（`layout-stress.sh`）；
/// - `-CuePadOffscreen YES`（仅 Mac）：主窗口放在所有屏幕之外（第一次显示前就放好、不被系统夹回，也不记位置），复现窗口不可见时的布局、测量时不露在桌面上；
/// - `-CuePadGeometryLoop YES`（仅 Mac）：挂一个刻意的几何回写环，给布局压力场景的检测器自检；
/// - `-CuePadCycle YES`：画面就绪后让演示会话 scratch 循环走过各种状态，录状态切换的动效（`cycleIfAsked`）；
/// - `-CuePadWake <秒>`（配 `-CuePadDemo YES`）：画面就绪后每隔这么久 Cue 被在线会话叫醒一次，录"叫醒"的动效（`wakeIfAsked`，见 `DebugScene+Cue.swift`）；`-CuePadWakeLog <路径>` 另量每次叫醒在 App 进程里的开销（同一处）；
/// - `-CuePadReduceMotion YES`：Cue 被叫醒的那一下按"减弱动态效果"打开来画（`CueWakeStage`；不碰系统设置，Mac 上那是用户这台机器的全局设置，系统的开关只读、覆盖不了整个窗口）；
/// - `-CuePadCueFocus YES`（配 cue 画面）：Cue 页的输入框一出现就聚焦（手机上聚焦才展开出模型与思考强度的胶囊）；
/// - `-CuePadToolsOpen YES`：会话页每一轮的经过一开始就展开整份清单（`RoundProcess`）；
/// - `-CuePadManyTasks <条数>`：给 `-CuePadProject` 那个项目再加这么多条待办（没做完的还不到这么多时），量任务多时的项目页（`perf-ios.sh 3 -CuePadManyTasks 150 -CuePadProject CuePad`）；
/// - `-CuePadTasksOpen YES`：项目页任务纸的"还有 N 条"与"已完成 M"一开始就展开；
/// - `-CuePadHover <正文开头>`（仅 Mac）：那张灵感卡或那条任务一出现就画成指针停着的样子（"设为任务"、亮起的"开始"）；
/// - `-CuePadShowsDone YES`（仅 iOS）：任务页的"最近完成"默认展开并滚到底；
/// - `-CuePadExplain YES`（仅 iOS）：推入页顶栏有说明时（会话需要 /reload）直接弹出，核对点标题的说明；
/// - `-CuePadCatalogFailure YES`：项目目录读取直接报错（重试也一样），核对读取失败画面；
///   `-CuePadCatalogFailure once`：每个窗口（含菜单栏面板）只有第一次读取报错，按"重试"后恢复，核对重试路径。
/// - `-CuePadSync <noAccount|decide|failed|syncing|restricted|conflicts>`：设置里 iCloud 同步按这个状态显示（`DebugScene+Sync.swift`）；
///   `-CuePadSync stalled`：装上同步永不返回的替身，核对下拉刷新的圈有时限；
/// - `-CuePadSampleCrash YES`：存一份样例崩溃诊断（配 `-CuePadCrashSheet YES` 直接打开摘要）；
/// - `-CuePadNotifications YES`（仅 Mac）：隔离库下也发真实的系统通知（规则见 docs/verify.md「通知（Mac）」）；
///   `-CuePadSampleCue <秒>`（仅 Mac）：过这么久写一条 Cue 请你允许推送的消息，经 Cue 的通知出口发出（隔离库里 Cue 不值班，不会自己推）；
/// 设置项可在参数域覆盖：`-theme dark`。
enum DebugScene {
    static var defaults: UserDefaults { .standard }
    static var scene: String? { defaults.string(forKey: "CuePadScene") }
    /// 搜索框预填的字：只认启动参数（参数域），不读已存的偏好（`UserDefaults.standard` 是真实的偏好域）。
    static var searchText: String {
        (UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["CuePadSearch"] as? String) ?? ""
    }
    /// Mac session 画面要打开的会话（演示会话的 sessionID 与会话名相同）。
    static var sessionToOpen: String? { scene == "session" ? defaults.string(forKey: "CuePadSession") : nil }
    /// 截图演示：编辑器载入后选中这一段（`起点:长度`，UTF-16）。
    static var editorSelection: NSRange? {
        guard let parts = defaults.string(forKey: "CuePadSelect")?.split(separator: ":").compactMap({ Int($0) }), parts.count == 2 else { return nil }
        return NSRange(location: parts[0], length: parts[1])
    }
    /// 挂上刻意的几何回写环（只给布局压力场景的检测器自检用）。
    static var injectsGeometryLoop: Bool { defaults.bool(forKey: "CuePadGeometryLoop") }
    /// 项目页任务纸点"还有 N 条"的那条路（`debugExposesTaskFold`，看得见的那一页上的纸）。
    static var toggleTaskFold: () -> Void = {}
    #if os(iOS)
    /// 点 Cue 页头开合面板的那条路（`debugExposesCuePanel`）。
    static var toggleCuePanel: () -> Void = {}
    #endif

    /// 第 `attempt` 次订阅项目目录（`Workspace.catalogAttempt`，从 0 起）是否按 `-CuePadCatalogFailure` 注入失败。
    static func injectCatalogFailure(attempt: Int) throws {
        let fails = defaults.string(forKey: "CuePadCatalogFailure") == "once" ? attempt == 0 : defaults.bool(forKey: "CuePadCatalogFailure")
        if fails { throw InjectedFailure() }
    }

    struct InjectedFailure: LocalizedError {
        var errorDescription: String? { "调试注入的读取失败（-CuePadCatalogFailure）" }
    }

    /// 需要时写入演示数据，并按参数选中项目；返回选中的项目。
    static func prepareLibrary(_ workspace: Workspace) async -> UUID? {
        let store = workspace.services.store
        // -CuePadSampleCrash YES：存一份样例崩溃诊断，设置里出现"上次崩溃"（配 -CuePadCrashSheet YES 直接打开摘要）
        if defaults.bool(forKey: "CuePadSampleCrash") { workspace.services.diagnostics.record([sampleCrash]) }
        #if os(macOS)
        if defaults.string(forKey: "CuePadSeed") == "perf", (try? await store.projects().isEmpty) == true {
            do { try await PerfLibrary.seed(store) } catch { workspace.fail(error) }
        }
        #endif
        if defaults.bool(forKey: "CuePadDemo"), (try? await store.projects().isEmpty) == true {
            do { try await DemoLibrary.seed(store) } catch { workspace.fail(error) }
        }
        if defaults.bool(forKey: "CuePadDemo") { await seedMacAgents(workspace.services) }
        await presetSync(workspace.services)
        guard let name = defaults.string(forKey: "CuePadProject"),
              let project = try? await store.projects().first(where: { $0.name == name })
        else { return nil }
        let many = defaults.integer(forKey: "CuePadManyTasks")
        if many > 0, ((try? await store.taskCounts(in: project.id).open) ?? 0) < many {
            for index in 1...many { _ = try? await store.createTask("压力任务 \(index)：画布与节点的一段说明", in: project.id) }
        }
        #if os(macOS)
        workspace.show(.project(project.id))
        #endif
        return project.id
    }

    /// `-CuePadComposer <cards|attachments|lines|slash>`（配 session、newsession 画面，iOS 与 Mac）：输入框出现时 cards 打开选卡片面板，slash 写进 "/re" 弹出斜杠命令面板，
    /// attachments 带上一张卡片（`-CuePadCard` 挑哪张）并放进两张演示图片，lines 写进 9 行文字（看文字区长到 6 行后在里面滚）。
    /// ＋ 菜单是系统菜单、不能代为展开：截图时按一下 ＋（iPhone 17 Pro 回复框：`axe touch -x 37 -y 810 --down --up --delay 0.15`；axe 的 tap 太快，菜单不开）。
    static func presetComposer(_ draft: Binding<ComposerDraft>, source: Binding<ComposerSource?>, store: CueStore) async {
        switch defaults.string(forKey: "CuePadComposer") {
        case "cards":
            // 等推入页面的转场走完再弹，转场中弹出的面板会被系统丢掉
            try? await Task.sleep(for: .seconds(1))
            source.wrappedValue = .cards
        case "attachments":
            // 先挑未分类里的，没有再挑第一个项目里的
            var id = await card(in: nil, store: store)
            if id == nil, let project = try? await store.projects().first { id = await card(in: project.id, store: store) }
            if let id, let card = try? await store.card(id) {
                draft.wrappedValue.attach(card)
            }
            draft.wrappedValue.images = [(0.85, 0.47, 0.29), (0.25, 0.56, 0.72)].map { PickedImage(data: swatch(red: $0.0, green: $0.1, blue: $0.2)) }
        case "lines":
            draft.wrappedValue.text = (1...9).map { "第 \($0) 行" }.joined(separator: "\n")
        case "slash":
            draft.wrappedValue.text = "/re"
        default:
            break
        }
    }

    /// 一块纯色的 PNG（演示图片）。
    private static func swatch(red: CGFloat, green: CGFloat, blue: CGFloat) -> Data {
        let size = CGSize(width: 240, height: 180)
        let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        return DemoLibrary.encode(context.makeImage()!)
    }

    /// `-CuePadCard` 指定（或最近修改）的一张散放的灵感。
    static func card(in project: UUID?, store: CueStore) async -> UUID? {
        let cards = (try? await store.cards(in: project)) ?? []
        let prefix = defaults.string(forKey: "CuePadCard") ?? ""
        return cards.filter { $0.body.hasPrefix(prefix) }.max { $0.modifiedAt < $1.modifiedAt }?.id
    }

    static func scrollIfNeeded(_ proxy: ScrollViewProxy) {
        guard scene == "older" else { return }
        later(.milliseconds(300)) { proxy.scrollTo(ScrollAnchor.older, anchor: UnitPoint(x: 0.5, y: 0.35)) }
    }

    /// 产品视图读的启动预设（`DebugHooks.preset`）。
    static var preset: DebugHooks.Preset {
        var preset = DebugHooks.Preset()
        preset.searchText = searchText
        preset.editorSelection = editorSelection
        preset.toolsOpen = defaults.bool(forKey: "CuePadToolsOpen")
        preset.explain = defaults.bool(forKey: "CuePadExplain")
        preset.openPreview = defaults.string(forKey: "CuePadOpenPreview")
        preset.crashSheet = defaults.bool(forKey: "CuePadCrashSheet")
        preset.demoMac = defaults.bool(forKey: "CuePadDemoMac")
        preset.alwaysReachable = preset.demoMac && defaults.string(forKey: "CuePadSync") == nil
        preset.quotaDetail = defaults.string(forKey: "CuePadQuotaDetail")
        preset.modelMenu = defaults.bool(forKey: "CuePadModelMenu")
        preset.cueFocus = defaults.bool(forKey: "CuePadCueFocus")
        preset.reducesMotion = defaults.bool(forKey: "CuePadReduceMotion")
        if defaults.bool(forKey: "CuePadTasksOpen") { preset.taskFold = TaskFold(showsAll: true, showsDone: true) }
        #if os(macOS)
        preset.hovered = defaults.string(forKey: "CuePadHover")
        #endif
        #if os(iOS)
        preset.showsDone = defaults.bool(forKey: "CuePadShowsDone")
        preset.briefOpen = defaults.bool(forKey: "CuePadBrief")
        preset.alertStatus = alertStatus
        if defaults.string(forKey: "CuePadSearchScope") == "sessions" { preset.searchScope = .sessions }
        preset.cuePanelOpen = defaults.bool(forKey: "CuePadCuePanel")
        #endif
        return preset
    }

    // MARK: 截图的首帧就绪

    /// 还没做完的摆画面的事（`later`）。
    private static var pending = 0
    /// 正在过渡的视图（`debugSettling`）。
    private static var unsettled: Set<UUID> = []

    static func settling(_ id: UUID, _ busy: Bool) {
        if busy { unsettled.insert(id) } else { unsettled.remove(id) }
    }

    static func later(_ delay: Duration, _ work: @escaping @MainActor () -> Void) {
        pending += 1
        Task {
            try? await Task.sleep(for: delay)
            work()
            pending -= 1
        }
    }

    /// `CUEPAD_SHOT_READY` 给了文件路径时，画面摆好（`prepare` 做完）之后等到：读库的结果都回来了、在线会话读到了第一份（`LiveSessions.items`，
    /// 侧栏与书架的项目要等它才排）、摆画面的事都做完了、
    /// 没有视图报着正在过渡、屏上没有进行中的一次性动画（转圈这类一直循环的不算），连着三帧都这样，再写下这个文件。`xc.sh shot` 等它出现才截图，不靠固定的等待。
    static func signalReady(_ services: AppServices) async {
        guard let path = ProcessInfo.processInfo.environment["CUEPAD_SHOT_READY"] else { return }
        var still = 0
        while still < 3 {
            // 排在页面已经发出的读库之后：它回来时，那些读取也都回来了
            _ = try? await services.store.projects()
            await NextFrame.wait()
            still = pending == 0 && unsettled.isEmpty && services.liveSessions.items != nil && !animating ? still + 1 : 0
        }
        FileManager.default.createFile(atPath: path, contents: nil)
    }

    private static let longestOneShot: CFTimeInterval = 5

    /// 屏上的窗口里有没有一次性的动画在跑（推入、弹出浮窗这类）；一直循环的（转圈、流光）不算。
    private static var animating: Bool {
        func busy(_ layer: CALayer) -> Bool {
            // 看不见的不算（没在刷新的下拉刷新圈也一直在转）
            guard !layer.isHidden, layer.opacity > 0 else { return false }
            let finite = (layer.animationKeys() ?? []).contains { key in
                guard let animation = layer.animation(forKey: key) else { return false }
                // 一次性的：总时长不过几秒。循环的（光标闪烁、转圈、玻璃的跟随）重复次数或时长是极大值，不等它们
                let total = animation.repeatDuration > 0 ? animation.repeatDuration : animation.duration * Double(max(animation.repeatCount, 1))
                return total.isFinite && total <= Self.longestOneShot
            }
            return finite || (layer.sublayers ?? []).contains(where: busy)
        }
        #if os(macOS)
        return NSApp.windows.filter(\.isVisible).compactMap(\.contentView?.superview?.layer).contains(where: busy)
        #else
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.map(\.layer).contains(where: busy)
        #endif
    }

}
#endif
