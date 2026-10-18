import CueStore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 产品代码通往调试画面的唯一入口：截图验收的启动预设、性能打点与几处测量钩子都经这里，产品视图不认识 `DebugScene`、
/// 也不写 `#if DEBUG`。Release 构建里预设全是空、钩子什么都不做（这个文件两种构建都编译，调试画面本身只在 Debug 里）。
enum DebugHooks {
    /// 截图验收的启动预设（`-CuePad…` 启动参数，见 `DebugScene`）：页面出现时按它摆好要拍的样子。
    struct Preset {
        /// 搜索框预填的字（`-CuePadSearch`）。
        var searchText = ""
        /// 编辑器载入后选中的一段（`-CuePadSelect`）。
        var editorSelection: NSRange?
        /// 每一轮的经过、子代理名册与 Cue 页折起的动态一开始就展开（`-CuePadToolsOpen`）。
        var toolsOpen = false
        /// 推入页顶栏有说明时直接弹出（`-CuePadExplain`）。
        var explain = false
        /// 会话页直接打开这张预览（`-CuePadOpenPreview <批的标题或文件名>`）。
        var openPreview: String?
        /// 设置里的崩溃报告直接弹出（`-CuePadCrashSheet`）。
        var crashSheet = false
        /// 演示 Mac 在本机库里接手发到 Mac 的话（`-CuePadDemoMac`）：隔离模式没有同步也送得到。
        var demoMac = false
        /// 说的话按同步一直通着算（`SpeechClock`）：演示 Mac 在本机库里接手、又没装同步替身时（替身自己报通断，`-CuePadSync`）。
        var alwaysReachable = false
        /// 回复框的模型菜单一出现就弹出（`-CuePadModelMenu`，Mac；菜单是独立窗口，截图另拍它）。
        var modelMenu = false
        /// Cue 页的输入框一出现就聚焦（`-CuePadCueFocus`）。
        var cueFocus = false
        /// 项目页任务纸的"还有 N 条"与"已完成 M"一开始就展开（`-CuePadTasksOpen`）。
        var taskFold = TaskFold()
        /// 整个窗口按"减弱动态效果"画（`-CuePadReduceMotion`，`PaletteProvider`）：验收时不碰系统设置。
        var reducesMotion = false
        #if os(macOS)
        /// 正文以它开头的那张灵感卡、那条任务或那一行（回收站按名字）一出现就画成指针停着的样子（`-CuePadHover`）：后台截图里指针进不来，
        /// 合成的鼠标移动事件也不触发不在前台的应用的悬停。
        var hovered: String?
        /// "运行情况"里垫在前面的几轮（`-CuePadRunRounds`）：每种醒来的原因各一轮；真的几轮只在值班的管理器内存里，隔离实例里没有大脑跑不出来。
        var runRounds: [CueRound] = []
        #endif
        #if os(iOS)
        /// 任务页的"最近完成"展开并滚到底（`-CuePadShowsDone`）。
        var showsDone = false
        /// 任务页一出现就弹出正文的编辑页（`-CuePadBrief`）。
        var briefOpen = false
        /// 设置页"Pi 通知"一行显示的状态（`-CuePadAlertStatus`；演示模式没有同步，真实状态出不来）。
        var alertStatus: PiAlertStatus?
        /// 搜索页一打开在哪个范围（`-CuePadSearchScope sessions`）。
        var searchScope = SearchScreen.Scope.cards
        /// Cue 页头一出现就展开成面板（`-CuePadCuePanel YES`；`end` 再滚到面板底，看额度与记忆）。
        var cuePanelOpen = false
        var cuePanelEnd = false
        #endif
    }

    #if os(macOS)
    /// 正文是这样开头的卡、任务、记忆或这一行（回收站按名字）是否按 `Preset.hovered` 一出现就画成悬停的样子。
    static func hovers(_ text: String) -> Bool { preset.hovered.map(text.hasPrefix) ?? false }
    #endif

    static let preset: Preset = {
        #if DEBUG
        DebugScene.preset
        #else
        Preset()
        #endif
    }()

    /// 同步从哪来：Debug 构建的 `-CuePadSync stalled` 换成拉取永不返回的替身（`DebugScene.StalledSync`），其余照常按 iCloud。
    static var syncSource: AppServices.SyncSource {
        #if DEBUG
        DebugScene.syncSource
        #else
        .iCloud
        #endif
    }

    /// 隔离库也连 iCloud：只给同步测量（docs/verify.md「同步测量」），只连 CloudKit 开发环境，见 `DebugScene.syncsIsolatedLibrary`。
    static var syncsIsolatedLibrary: Bool {
        #if DEBUG && os(macOS)
        DebugScene.syncsIsolatedLibrary
        #else
        false
        #endif
    }

    /// 同步测量里代替手机的实例按手机开着 Agent 页的节奏拉（`-CuePadSyncBench remote`，见 `SyncBench`）。
    static var pollsLikePhone: Bool {
        #if DEBUG && os(macOS)
        DebugScene.defaults.string(forKey: "CuePadSyncBench") == "remote"
        #else
        false
        #endif
    }

    /// 隔离库下这台 Mac 的标识换成 `-CuePadHost <名>`：同一台机器上开两个隔离实例当两台 Mac（同步测量）。nil：用硬件标识。
    static var hostID: String? {
        #if DEBUG
        DebugScene.defaults.string(forKey: "CuePadHost").map { "mac-\($0)" }
        #else
        nil
        #endif
    }

    /// 隔离库下 Cue 的大脑换成 `-CuePadCueBrain <可执行文件>`（按所选运行时的协议说话的替身，如量值班开销用的假 Pi）：隔离目录里没有登录的运行时，
    /// 真的大脑起不来。nil：用检测挑中的。
    static var cueBrain: URL? {
        #if DEBUG
        DebugScene.defaults.string(forKey: "CuePadCueBrain").map { URL(filePath: $0) }
        #else
        nil
        #endif
    }

    /// 不请求通知权限：演示与脚本截图、录屏（`-CuePadDemo` 或给了 `CUEPAD_SHOT_READY`）里系统弹窗会盖住画面，没人去点。
    static var asksNotificationPermission: Bool {
        #if DEBUG
        !DebugScene.defaults.bool(forKey: "CuePadDemo") && ProcessInfo.processInfo.environment["CUEPAD_SHOT_READY"] == nil
        #else
        true
        #endif
    }

    /// 启动参数（`-theme dark` 这类）覆盖已存的设置，只在 Debug 构建生效：视觉验收要用，发布版不能被命令行参数改设置。
    /// 标准偏好域自带这层覆盖；隔离模式的套件读不到，所以显式传入。
    static var launchArgumentOverrides: [String: Any] {
        #if DEBUG
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        #else
        [:]
        #endif
    }

    /// 发布版不让启动参数改设置：标准偏好域自带一层启动参数覆盖，Release 里把它去掉；Debug 里留着给视觉验收用。
    static func dropLaunchArguments(from defaults: UserDefaults) {
        #if !DEBUG
        if defaults === UserDefaults.standard { defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain) }
        #endif
    }

    /// 稍后做一件摆画面的事（如编辑器载入后选中一段）：Debug 里记作"还在摆"，截图的就绪标记等它做完。
    static func later(_ delay: Duration = .zero, _ work: @escaping @MainActor () -> Void) {
        #if DEBUG
        DebugScene.later(delay, work)
        #else
        Task {
            try? await Task.sleep(for: delay)
            work()
        }
        #endif
    }

    /// 性能打点：某件事出现了（`interact` 等它、量到它用了多久，见 `PerfProbe`）。
    static func mark(_ event: String) {
        #if DEBUG
        PerfProbe.mark(event)
        #endif
    }

    /// 对话在上面再排开一段（`SessionChat`），排开后最早一条是全部 `count` 条里的第 `item` 条：`-CuePadBench chatdepth` 从这一刻量。
    static func chatShowsEarlier(from item: Int, of count: Int) {
        #if DEBUG && os(iOS)
        ChatDepthBench.began(from: item, of: count)
        #endif
    }

    /// 输入框出现时按 `-CuePadComposer` 摆好要拍的样子（打开选卡片面板、预填文字或附件）。
    static func presetComposer(_ draft: Binding<ComposerDraft>, source: Binding<ComposerSource?>, store: CueStore) async {
        #if DEBUG
        await DebugScene.presetComposer(draft, source: source, store: store)
        #endif
    }

    /// "对 Cue 说"的输入框或会话回复框（`session`）出现时：`-CuePadSpeech press` 在它出现 3 秒后按一下它的发送钮
    /// （`press` 就是点按发送钮做的事），录屏看发出的那一下。
    static func pressSendIfAsked(session: Bool, _ press: () -> Void) async {
        #if DEBUG
        await DebugScene.pressSendIfAsked(session: session, press)
        #endif
    }

    /// 预览网页要打开了（`PreviewWeb`）：`-CuePadWebSnapshot` 在这里拍一张同样规则下载入完的快照。
    static func previewWebLoaded(_ file: URL) {
        #if DEBUG
        DebugScene.snapshotWeb(file)
        #endif
    }

    /// 第 `attempt` 次订阅项目目录之前：`-CuePadCatalogFailure` 在这里注入读取失败。
    static func willReadCatalog(attempt: Int) throws {
        #if DEBUG
        try DebugScene.injectCatalogFailure(attempt: attempt)
        #endif
    }

    #if os(macOS)
    /// 主窗口的类：Debug 里是不被系统夹回屏幕内的 `DebugWindow`（`-CuePadOffscreen`）。
    #if DEBUG
    typealias MainWindowClass = DebugWindow
    #else
    typealias MainWindowClass = MainShellWindow
    #endif

    /// 脚本截图（给了 `CUEPAD_SHOT_READY`）：App 在后台跑，主窗口排在所有窗口最后——不抢前台和键盘，也不盖住正在用的窗口；
    /// 按窗口截图截得到被挡住的窗口。
    static var staysInBackground: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["CUEPAD_SHOT_READY"] != nil
        #else
        false
        #endif
    }

    /// 本机构建活不过起它的进程（xc.sh 的看守、perf 脚本、会话自己写的测量脚本）：起它的进程退出或被杀，实例经 `terminate` 正常退出，
    /// 不留下没人收的实例。父进程是 launchd（经 LaunchServices 起：Xcode、访达、测试宿主）时不跟。
    static func exitsWithParent(_ terminate: @escaping @Sendable () -> Void) -> (any DispatchSourceProtocol)? {
        #if DEBUG
        let parent = getppid()
        guard parent != 1 else { return nil }
        let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .global())
        source.setEventHandler(handler: terminate)
        source.resume()
        if getppid() != parent { terminate() }  // 装上之前它就退了
        return source
        #else
        nil
        #endif
    }

    /// 显示主窗口或设置窗口：平时到最前并接过键盘；脚本截图时排在最后（`staysInBackground`）。
    static func present(_ window: NSWindow) {
        if staysInBackground { window.orderBack(nil) } else { window.makeKeyAndOrderFront(nil) }
    }

    /// 隔离库下也发真实的系统通知、装提示音、设角标（`-CuePadNotifications YES`，见 `AlertCenter.delivers`）。
    static var deliversNotifications: Bool {
        #if DEBUG
        DebugScene.defaults.bool(forKey: "CuePadNotifications")
        #else
        false
        #endif
    }

    /// 隔离模式下的更新器：`-CuePadScene updatewait` 给一个演示用的（找到更新、点了安装，不真装），其余没有。
    static var updater: (any AppUpdater)? {
        #if DEBUG
        DebugScene.scene == "updatewait" ? DebugScene.DemoUpdater() : nil
        #else
        nil
        #endif
    }

    /// `-CuePadOffscreen`：主窗口放到所有屏幕之外、不记位置，返回 true；否则什么都不做。
    static func placesOffscreen(_ window: NSWindow) -> Bool {
        #if DEBUG
        guard DebugScene.offscreen else { return false }
        DebugScene.placeOffscreen(window)
        return true
        #else
        false
        #endif
    }
    #endif
}

extension View {
    #if os(iOS)
    /// 点 Cue 页头开合面板的那条路交给测量（`IOSInteractionBench` 的"开合 Cue 面板"）。
    func debugExposesCuePanel(_ toggle: @escaping () -> Void) -> some View {
        #if DEBUG
        onAppear { DebugScene.toggleCuePanel = toggle }
        #else
        self
        #endif
    }
    #endif

    /// 项目页任务纸点"还有 N 条"的那条路交给测量（两端 `InteractionBench` 的"展开任务"）：看得见的那一页（`active`）的纸。
    func debugExposesTaskFold(active: Bool = true, _ toggle: @escaping () -> Void) -> some View {
        #if DEBUG
        onChange(of: active, initial: true) { if active { DebugScene.toggleTaskFold = toggle } }
        #else
        self
        #endif
    }

    /// 这一处正在过渡（如编辑页正在淡入）：截图的就绪标记等它停下。SwiftUI 自己驱动的动画在图层上看不出来，由视图自己报。
    func debugSettling(_ busy: Bool) -> some View {
        #if DEBUG
        modifier(DebugSettling(busy: busy))
        #else
        self
        #endif
    }

    /// `older` 画面：墙排好（`ready`）后滚到"更早"。
    func debugScrollsToOlder(_ proxy: ScrollViewProxy, ready: Bool) -> some View {
        #if DEBUG
        onChange(of: ready) { if ready { DebugScene.scrollIfNeeded(proxy) } }
        #else
        self
        #endif
    }

    #if os(macOS)
    /// 主窗口根上：按启动参数摆好调试画面、挂上自检用的布局环，摆好后报"首帧就绪"（`xc.sh shot` 等它再截图）。
    func debugScene(_ workspace: Workspace) -> some View {
        #if DEBUG
        task {
            await DebugScene.prepare(workspace)
            await DebugScene.signalReady(workspace.services)
            // 接力与关窗不挂在窗口内容上：关窗时内容摘下（`MainShellWindow`），内容上的任务跟着停
            Task { await DebugScene.wakeIfAsked(workspace) }
            Task { await DebugScene.relayIfAsked(workspace) }
            Task { await DebugScene.closeIfAsked(workspace) }
            Task { await DebugScene.openMenuIfAsked() }
            await DebugScene.cycleIfAsked(workspace.services)
        }
        .background { if DebugScene.injectsGeometryLoop { GeometryLoopProbe() } }
        #else
        self
        #endif
    }
    #endif

    #if os(iOS)
    /// 窗口根上：按启动参数摆好调试画面（样板页盖在最上层），摆好后报"首帧就绪"（`xc.sh shot` 等它再截图）。
    func debugScene(_ workspace: Workspace, _ navigation: Navigation) -> some View {
        #if DEBUG
        overlay {
            // 盖在根上（在注入配色的那层外面），自己按外观取配色
            Group {
                switch DebugScene.scene {
                case "style": StyleBoard()
                case "icons": IconSheet()
                case "widgets": DebugWidgetStage()
                case "share": DebugShareStage(location: workspace.services.location)
                default: EmptyView()
                }
                if let kind = DebugScene.defaults.string(forKey: "CuePadRowMenu") {
                    // 盖在根上，在注入环境的那层外面：菜单项要的工作区自己带上
                    DebugRowMenu(kind: kind).environment(workspace).environment(workspace.services).environment(navigation)
                }
            }
            .withPalette()
        }
            .task {
                await DebugScene.prepare(workspace, navigation)
                await DebugScene.openMenuIfAsked()
                await DebugScene.signalReady(workspace.services)
                async let wakes: Void = DebugScene.wakeIfAsked(workspace)
                async let relays: Void = DebugScene.relayIfAsked(workspace)
                await DebugScene.cycleIfAsked(workspace.services)
                _ = await (wakes, relays)
            }
        #else
        self
        #endif
    }
    #endif
}

#if DEBUG
private struct DebugSettling: ViewModifier {
    let busy: Bool
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: busy, initial: true) { DebugScene.settling(id, busy) }
            .onDisappear { DebugScene.settling(id, false) }
    }
}
#endif

#if os(macOS)
/// 主窗口的内容：截图只截主窗口，调试画面要拍的另一扇窗（菜单栏面板、项目表单、新会话）放进主窗口里拍；其余是 `main`。
struct DebugStage<Main: View>: View {
    let workspace: Workspace
    @ViewBuilder let main: () -> Main

    var body: some View {
        #if DEBUG
        switch DebugScene.scene {
        case "menubar": DebugMenuBarStage().environment(workspace)
        case "cuebar": DebugMenuBarStage(cueBar: true).environment(workspace)
        case "projectform": ProjectForm(project: nil).environment(workspace).frame(maxWidth: .infinity, maxHeight: .infinity)
        case "newsession": DebugNewSessionForm().environment(workspace).frame(maxWidth: .infinity, maxHeight: .infinity)
        default: main()
        }
        #else
        main()
        #endif
    }
}
#endif
