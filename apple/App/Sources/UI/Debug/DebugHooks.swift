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
        /// 会话页每一轮的工具清单一开始就展开（`-CuePadToolsOpen`）。
        var toolsOpen = false
        /// 推入页顶栏有说明时直接弹出（`-CuePadExplain`）。
        var explain = false
        /// 会话页直接打开这张预览（`-CuePadOpenPreview <标题>`）。
        var openPreview: String?
        /// 设置里的崩溃报告直接弹出（`-CuePadCrashSheet`）。
        var crashSheet = false
        /// 演示 Mac 在本机库里接手发到 Mac 的话（`-CuePadDemoMac`）：隔离模式没有同步也送得到。
        var demoMac = false
        #if os(iOS)
        /// 任务页的"最近完成"展开并滚到底（`-CuePadShowsDone`）。
        var showsDone = false
        /// 设置页"Pi 通知"一行显示的状态（`-CuePadAlertStatus`；演示模式没有同步引擎，真实状态出不来）。
        var alertStatus: PiAlertStatus?
        /// 一出现就聚焦并预填的搜索框：书架顶上的，或项目页的下拉搜索。
        var focusedSearch: SearchFocus?
        /// Agent 页一出现就填进搜索框的字（`agent` 画面）。
        var agentQuery: String?
        /// Agent 页从底部（最早的历史）看起（`agent` 画面配 `-CuePadHistory`、没有搜索时）。
        var agentFromBottom = false
        #endif
    }

    #if os(iOS)
    enum SearchFocus { case shelf, project }
    #endif

    @MainActor static let preset: Preset = {
        #if DEBUG
        DebugScene.preset
        #else
        Preset()
        #endif
    }()

    /// 启动参数（`-theme dark` 这类）覆盖已存的设置，只在 Debug 构建生效：视觉验收要用，发布版不能被命令行参数改设置。
    /// 标准偏好域自带这层覆盖；隔离模式的套件读不到，所以显式传入。
    static var launchArgumentOverrides: [String: Any] {
        #if DEBUG
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        #else
        [:]
        #endif
    }

    /// 稍后做一件摆画面的事（如编辑器载入后选中一段）：Debug 里记作"还在摆"，截图的就绪标记等它做完。
    @MainActor static func later(_ delay: Duration = .zero, _ work: @escaping @MainActor () -> Void) {
        #if DEBUG
        DebugScene.later(delay, work)
        #else
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            work()
        }
        #endif
    }

    /// 性能打点：某件事第一次出现（测量脚本等它，见 `PerfProbe`）。
    @MainActor static func mark(_ event: String) {
        #if DEBUG && os(macOS)
        PerfProbe.mark(event)
        #endif
    }

    /// 第 `attempt` 次订阅项目目录之前：`-CuePadCatalogFailure` 在这里注入读取失败。
    @MainActor static func willReadCatalog(attempt: Int) throws {
        #if DEBUG
        try DebugScene.injectCatalogFailure(attempt: attempt)
        #endif
    }

    #if os(macOS)
    /// 主窗口的类：Debug 里是不被系统夹回屏幕内的 `DebugWindow`（`-CuePadOffscreen`）。
    #if DEBUG
    typealias MainWindowClass = DebugWindow
    #else
    typealias MainWindowClass = NSWindow
    #endif

    /// `-CuePadOffscreen`：主窗口放到所有屏幕之外、不记位置，返回 true；否则什么都不做。
    @MainActor static func placesOffscreen(_ window: NSWindow) -> Bool {
        #if DEBUG
        guard DebugScene.offscreen else { return false }
        DebugScene.placeOffscreen(window)
        return true
        #else
        false
        #endif
    }

    /// 悬停进入或离开一次（压力场景核对没有来回翻转的循环）。
    @MainActor static func hoverToggled() {
        #if DEBUG
        DebugScene.hoverToggles += 1
        #endif
    }
    #endif

    #if os(iOS)
    /// 底部栏换标签的那条路（含推移，`TabsRoot` 挂上）：测量脚本按它换标签。
    @MainActor static var selectTab: (Navigation.Tab) -> Void = { _ in }

    /// App 启动、界面出现之前：`-CuePadColdTap <会话记录 id>` 复现冷启动被通知拉起。
    @MainActor static func launched(alerts: PiAlertCenter) {
        #if DEBUG
        DebugScene.coldTap(alerts)
        #endif
    }
    #endif
}

extension View {
    /// 性能打点：这一页出现时（见 `DebugHooks.mark`）。
    func perfMark(_ event: String) -> some View {
        #if DEBUG
        onAppear { DebugHooks.mark(event) }
        #else
        self
        #endif
    }

    /// 性能打点：`value` 每变一次（如搜索结果到了）。
    func perfMark(_ event: String, onChangeOf value: some Equatable) -> some View {
        #if DEBUG
        onChange(of: value) { DebugHooks.mark(event) }
        #else
        self
        #endif
    }

    /// 这一处正在过渡（如纸页正在铺开）：截图的就绪标记等它停下。SwiftUI 自己驱动的动画在图层上看不出来，由视图自己报。
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
            await DebugScene.signalReady(workspace.services.store)
        }
        .background { if DebugScene.injectsGeometryLoop { GeometryLoopProbe() } }
        #else
        self
        #endif
    }
    #endif

    #if os(iOS)
    /// 窗口根上：按启动参数摆好调试画面（样板页盖在最上层），摆好后报"首帧就绪"（`xc.sh shot` 等它再截图）。
    func debugScene(_ workspace: Workspace, _ navigation: Navigation, _ alerts: PiAlertCenter) -> some View {
        #if DEBUG
        overlay { if DebugScene.scene == "style" { StyleBoard() } }
            .task {
                await DebugScene.prepare(workspace, navigation, alerts)
                await DebugScene.signalReady(workspace.services.store)
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
/// 主窗口的内容：截图只截主窗口，调试画面要拍的另一扇窗（菜单栏面板、设置、项目表单、新会话）放进主窗口里拍；其余是 `main`。
struct DebugStage<Main: View>: View {
    let workspace: Workspace
    @ViewBuilder let main: () -> Main

    var body: some View {
        #if DEBUG
        switch DebugScene.scene {
        case "menubar": DebugMenuBarStage().environment(workspace)
        case "settings": SettingsView().panelHost().frame(maxWidth: .infinity, maxHeight: .infinity)
        case "projectform": ProjectForm(project: nil).environment(workspace).frame(maxWidth: .infinity, maxHeight: .infinity)
        case "newsession": NewSessionForm { _ in }.environment(workspace).frame(maxWidth: .infinity, maxHeight: .infinity)
        default: main()
        }
        #else
        main()
        #endif
    }
}
#endif
