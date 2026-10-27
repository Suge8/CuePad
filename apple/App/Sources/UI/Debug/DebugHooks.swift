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
        /// 设置里的崩溃报告直接弹出（`-CuePadCrashSheet`）。
        var crashSheet = false
        /// 演示 Mac 在本机库里接手发到 Mac 的话（`-CuePadDemoMac`）：隔离模式没有同步也送得到。
        var demoMac = false
        /// 说的话按同步一直通着算（`SpeechClock`）：演示 Mac 在本机库里接手、走 Cue 流程演示（`-CuePadCueFlow`）或摆 Cue 的话在路上（`-CuePadCuePresence sending`），又没装同步替身时（替身自己报通断，`-CuePadSync`）。
        var alwaysReachable = false
        /// 回复框的模型菜单一出现就弹出（`-CuePadModelMenu`，Mac；菜单是独立窗口，截图另拍它）。
        var modelMenu = false
        /// Cue 页的输入框一出现就聚焦（`-CuePadCueFocus`）。
        var cueFocus = false
        /// 项目页任务纸的"还有 N 条"与"已完成 M"一开始就展开（`-CuePadTasksOpen`）。
        var taskFold = TaskFold()
        /// 整个窗口按"减弱动态效果"画（`-CuePadReduceMotion`，`PaletteProvider`）：验收时不碰系统设置。
        var reducesMotion = false
        /// 整个窗口按最大的辅助字号画（`-CuePadLargestType`，`PaletteProvider`）：同上，不碰系统设置。
        var largestType = false
        #if os(macOS)
        /// 窗口里这几点（左上为原点，同 `-CuePadClick`）上的按钮、行与卡一出现就画成指针停着的样子（`-CuePadHover x,y[;x,y…]`，`presetHover`）：
        /// 后台截图里指针进不来，合成的鼠标移动事件也不触发不在前台的应用的悬停。一张图里看几处时给几个点。
        var hovered: [CGPoint] = []
        #endif
        /// 进展页已完成列的"更早做完的"一开始就展开（`-CuePadShowsDone`）。
        var showsDone = false
        /// Cue 此刻钉成这一份样例（`-CuePadCueNow <样例>`，`CueNowSamples`）：页头、侧栏、小组件与实时活动都按它画，截各态用。
        var cueNow: CueNow?
        /// 额度环一出现就展开明细（`-CuePadQuotaOpen YES`：手机进展页顶栏、Mac 侧栏）。
        var quotaOpen = false
        /// 定时一出现就原地展开改（`-CuePadScheduleOpen YES`）：任务气泡里那一条、"记得什么"里"到点"的那一块。
        var scheduleOpen = false
        /// 规则的文件页一打开就是合并前标出会并进来的段（`-CuePadMergePreview YES`）。
        var mergePreview = false
        /// 技能与规则页一打开在哪一段（`-CuePadLibraryTab skills`，两端的 library 场景设给 `Workspace.libraryPane`）。
        var libraryPane = LibraryPane.rules
        #if os(iOS)
        /// 设置页通知那一行显示的状态（`-CuePadAlertStatus`；演示模式没有同步，真实状态出不来）。
        var alertStatus: PiAlertStatus?
        /// 搜索页一打开在哪个范围（`-CuePadSearchScope sessions`）。
        var searchScope = SearchScope.cards
        /// Cue 页头一出现就展开成面板（`-CuePadCuePanel YES`）。
        var cuePanelOpen = false
        /// 不弹演示会话的前台横幅（`-CuePadQuiet YES`）。
        var quietAlerts = false
        #endif
    }

    #if os(macOS)
    #endif

    static let preset: Preset = {
        #if DEBUG
        DebugScene.preset
        #else
        Preset()
        #endif
    }()

    /// 同步从哪来：Debug 构建的 `-CuePadSync stalled` 换成拉取永不返回的替身，`-CuePadSync <状态>` 换成报这个状态的替身（`DebugScene.StandInSync`），其余照常按 iCloud。
    static var syncSource: AppServices.SyncSource {
        #if DEBUG
        DebugScene.syncSource
        #else
        .iCloud
        #endif
    }

    /// 隔离库也连 iCloud：只给同步测量（docs/perf.md「同步测量」），只连 CloudKit 开发环境，见 `DebugScene.syncsIsolatedLibrary`。
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

    /// 隔离库下 Cue 的大脑换成 `-CuePadCueBrain <可执行文件>`：隔离目录里没有登录的运行时，真的大脑起不来。nil：用检测挑中的。
    static var cueBrain: URL? {
        #if DEBUG
        DebugScene.defaults.string(forKey: "CuePadCueBrain").map { URL(filePath: $0) }
        #else
        nil
        #endif
    }

    /// 隔离库下 Agent 当作装在这个家目录里（`-CuePadAgentHome <目录>`）：只在它的 `.local/bin` 里找，装、登录也按它当 HOME、PATH 只有系统目录，
    /// 像一台什么都没装的 Mac。给一个空目录就是一家都没装；点"安装"真去跑官方脚本，装进这个目录，不碰真实的家目录。
    static var agentHome: URL? {
        #if DEBUG
        DebugScene.defaults.string(forKey: "CuePadAgentHome").map { URL(filePath: $0, directoryHint: .isDirectory) }
        #else
        nil
        #endif
    }

    /// 脚本起的实例也像正式版那样首次打开时请工作区决定弹不弹接入面板（`-CuePadOfferSetup YES`，同一个 `Workspace.offerSetup`）：验收第一次打开与老用户升级后自动弹的那一次。
    static var offersSetup: Bool {
        #if DEBUG
        DebugScene.defaults.bool(forKey: "CuePadOfferSetup")
        #else
        false
        #endif
    }

    /// 指定的隔离库当作本机构建的开发库来定碰不碰真实世界（`-CuePadActsAs development|stranger`，`LibraryLocation.touchesRealWorld`）：
    /// development 照真的去找这台装没装正式版（维护者的 Mac），stranger 当作没装（克隆仓库自己编的人：接入真实的 Agent、发通知）。
    /// 各家配置目录、命令行链接、连接目录与工作区照样由 xc.sh 给的环境变量（app_env.py 的 `isolated_env`）换进隔离库，换不走的（通知权限、主机标识）是真的。
    enum ActsAs: String { case development, stranger }
    static var actsAs: ActsAs? {
        #if DEBUG
        DebugScene.defaults.string(forKey: "CuePadActsAs").flatMap(ActsAs.init)
        #else
        nil
        #endif
    }

    /// 脚本起的实例（带就绪文件 `DebugScene.readyFile`：截图、录屏、交互验收、测量）；测试宿主不算。Mac 上当作有人在看（`CueViewing`）。
    static var scripted: Bool {
        #if DEBUG
        DebugScene.readyFile != nil
        #else
        false
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
        #if os(macOS)
        LaunchBench.mark(event)
        #endif
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

    #if os(macOS)
    /// 全屏预览的翻页开始接本窗口的滚动（`PageInput`）：`-CuePadClick` 合成的滑动先过它（`DebugScene.scrollGate`）。
    static func previewScrolls(_ takes: @escaping (NSEvent) -> Bool) {
        #if DEBUG
        DebugScene.scrollGate = takes
        #endif
    }
    #endif

    /// 第 `attempt` 次订阅项目目录之前：`-CuePadCatalogFailure` 在这里注入读取失败。
    /// 隔离库下也要通知权限、发真实的系统通知、装提示音、设角标（`-CuePadNotifications YES`，见 `AlertCenter.delivers`）。
    static var deliversNotifications: Bool {
        #if DEBUG
        DebugScene.defaults.bool(forKey: "CuePadNotifications")
        #else
        false
        #endif
    }

    /// 隔离库下也开实时活动（`-CuePadLiveActivity YES`，见 `AppServices.cueActivity`）：验收锁屏与灵动岛时用，用完结束掉。
    static var opensLiveActivity: Bool {
        #if DEBUG
        DebugScene.defaults.bool(forKey: "CuePadLiveActivity")
        #else
        false
        #endif
    }

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

    /// 进到 `main`：`-CuePadBench launch` 从这里量冷启动（`LaunchBench`）。
    static func launching() {
        #if DEBUG
        LaunchBench.start()
        #endif
    }

    /// 资料库没能打开。量的时候（`-CuePadBench`）没人去点失败页，量的脚本会一直等：报出原因（`BENCH-ERR` 一行）后以 1 退出。
    static func libraryFailed(_ reason: String) {
        #if DEBUG
        guard DebugScene.defaults.string(forKey: "CuePadBench") != nil else { return }
        print("BENCH-ERR 资料库没能打开：\(reason)")
        fflush(stdout)
        exit(1)
        #endif
    }

    /// 退出前把借走的前台与指针还回去（`DebugForeground`）。
    static func willTerminate() {
        #if DEBUG
        DebugForeground.giveBack()
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

    /// 显示窗口：到最前并接过键盘（`activating` 时连 App 一起到前台）。本机构建（DEBUG 条件，含 perf 的 Release）不管谁起的都在后台：
    /// 窗口排在所有窗口最后，不抢前台和键盘、不盖住正在用的窗口，按窗口截图照样截得到；非占前台不可的只经 `DebugForeground` 借。
    static func present(_ window: NSWindow, activating: Bool = false) {
        #if DEBUG
        window.orderBack(nil)
        LaunchBench.present(window)
        #else
        if activating { NSApp.activate() }
        window.makeKeyAndOrderFront(nil)
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
