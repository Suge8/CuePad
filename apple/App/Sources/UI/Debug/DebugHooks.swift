import CueStore
import SwiftUI
#if os(macOS)
import AppKit
#endif

enum DebugHooks {
    nonisolated static let args = DebugArgs.launch

    /// 调试画面钉住的 Cue 此刻（`-CuePadCueNow` 起来就钉、`-CuePadCueCycle` 轮流换，`DebugScene.pinned`）：钉着就不随库变。
    static var cueNow: CueNow? {
        #if DEBUG
        DebugScene.pinned.cueNow
        #else
        nil
        #endif
    }

    /// 同步从哪来：Debug 构建的 `-CuePadSync stalled` 换成拉取永不返回的替身，`-CuePadSync <状态>` 换成报这个状态的替身（`DebugScene.StandInSync`），其余照常按 iCloud。
    static var syncSource: AppServices.SyncSource {
        #if DEBUG
        DebugScene.syncSource
        #else
        .iCloud
        #endif
    }

    /// 隔离库也同步：模拟云（任何平台），或连 CloudKit 开发环境（`-CuePadCloudKit YES`：Mac 是同步测量，限流与这台的正式版共用，只经 sync-bench.py，见 `DebugScene.syncsIsolatedLibrary`；
    /// 模拟器是真云验收，用模拟器里登着的测试账号，没登就是没有账号、不同步）。
    static var syncsIsolatedLibrary: Bool {
        #if DEBUG && os(macOS)
        args.sharedCloud != nil || DebugScene.syncsIsolatedLibrary
        #elseif targetEnvironment(simulator)
        args.sharedCloud != nil || args.cloudKit
        #else
        args.sharedCloud != nil
        #endif
    }

    static var liveHosts: [String] {
        #if DEBUG
        DebugScene.args.demo ? DebugScene.demoHosts : []
        #else
        []
        #endif
    }

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

    static func later(_ delay: Duration = .zero, fileID: String = #fileID, line: Int = #line, _ work: @escaping @MainActor () -> Void) {
        #if DEBUG
        DebugScene.later(delay, fileID: fileID, line: line, work)
        #else
        Task {
            try await Task.sleep(for: delay)
            work()
        }
        #endif
    }

    #if os(iOS)
    static func barFaded(_ hidden: Bool, navigation: UINavigationController?) {
        #if DEBUG
        let pop = navigation?.interactivePopGestureRecognizer
        let line = "bar-fade hidden=\(hidden) alpha-target=\(hidden ? 0 : 1) pop-enabled=\(pop?.isEnabled ?? false) bar-hidden=\(navigation?.isNavigationBarHidden ?? true) "
            + "back-hidden=\(navigation?.topViewController?.navigationItem.hidesBackButton ?? true) stack=\(navigation?.viewControllers.count ?? 0)\n"
        FileHandle.standardError.write(Data(line.utf8))
        #endif
    }

    static func readerLayers(outsideCue: Bool, drawer: Bool) {
        #if DEBUG
        FileHandle.standardError.write(Data("reader-hidden outside-cue=\(outsideCue) cue-in-drawer=\(drawer)\n".utf8))
        #endif
    }
    #endif

    static func drawerEscape(hung: Bool) {
        #if DEBUG
        FileHandle.standardError.write(Data("drawer-escape hung=\(hung)\n".utf8))
        #endif
    }

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

    /// 输入框里选的附件存进附件目录之前停多久：`-CuePadImportDelay <秒>` 把"附件还在存"拉长到能在界面上看见（配 `-CuePadSpeech press`）。
    static func importDelay() async {
        #if DEBUG
        if importDelaySeconds > 0 { try? await Task.sleep(for: .seconds(importDelaySeconds)) }
        #endif
    }

    #if DEBUG
    static var importDelaySeconds = DebugScene.args.driveOpts.importDelay
    #endif

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
    static func previewScrolls(_ takes: @escaping (NSEvent) -> Bool) {
        #if DEBUG
        DebugScene.scrollGate = takes
        #endif
    }
    #endif

    static func willReadCatalog(attempt: Int) throws {
        #if DEBUG
        try DebugScene.injectCatalogFailure(attempt: attempt)
        #endif
    }

    /// 资料库没能打开。脚本起的实例没人去点失败页，等它的脚本只会等到时限、说不出原因（如沿用旧检出留下的、早于 `baseVersion` 的隔离库）：
    /// 量的时候（`-CuePadBench`）报 `BENCH-ERR` 一行，其余脚本实例同 `DebugScene.abandon`，都以 1 退出。
    static func libraryFailed(_ failure: LibraryFailure) {
        #if DEBUG
        if DebugScene.args.driveOpts.bench != nil {
            print("BENCH-ERR 资料库没能打开：\(failure.reason)")
            fflush(stdout)
            exit(1)
        }
        if scripted { DebugScene.abandon("资料库没能打开", DebugScene.Unmet(failure.diagnostics)) }
        #endif
    }

    #if os(macOS)
    #if DEBUG
    typealias MainWindowClass = DebugWindow
    #else
    typealias MainWindowClass = MainShellWindow
    #endif

    /// 进到 `main`：先查用户在不在才许借前台（`DebugForeground`），再从这里量冷启动（`-CuePadBench launch`，`LaunchBench`）。
    static func launching() {
        #if DEBUG
        DebugForeground.requireUserAway()
        LaunchBench.start()
        #endif
    }

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
        if getppid() != parent { terminate() }
        return source
        #else
        nil
        #endif
    }

    /// 本机构建（DEBUG 条件，含 perf 的 Release）的窗口不管谁起的都在后台：排在所有窗口最后，不抢前台和键盘、不盖住正在用的窗口，按窗口截图照样截得到；
    /// 非占前台不可的只经 `DebugForeground` 借，人要看的用 `-CuePadOnTop YES`。摆好了返回 true（`NSWindow.present` 就不再到前台）。
    static func keepsBehind(_ window: NSWindow) -> Bool {
        #if DEBUG
        if DebugScene.args.layoutOpts.onTop { window.orderFrontRegardless() } else { window.orderBack(nil) }
        LaunchBench.present(window)
        return true
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
