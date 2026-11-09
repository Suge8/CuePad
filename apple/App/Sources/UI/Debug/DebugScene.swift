import CueStore
import SwiftUI

enum ScrollAnchor {
    static let older = "older"
}

#if DEBUG

/// 调试画面（只在 Debug 构建里，视觉验收、录屏、测量用）。启动参数的登记表是 `DebugArgs`（`DebugScene+Args*.swift`，字段注释即说明），画面的登记表是 `entries`（`DebugScene+Scenes.swift`）。
enum DebugScene {
    nonisolated static let args = DebugArgs.launch
    /// 运行时可改的偏好域，只给 `-CuePadImportDelay`：测试在进程里设它（`AttachmentImportTests`），冻结的 `args` 跟不上。
    static var defaults: UserDefaults { .standard }
    static var scene: String? { args.scene }
    /// `-CuePadWindowSize <宽>x<高>`：主窗口尺寸（Mac `resizeWindow`、iPad `debugCompact`）；没给或写错为 nil。
    static var windowSize: CGSize? {
        let parts = args.layoutOpts.windowSize?.split(separator: "x").compactMap { Double($0) } ?? []
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }
    static var searchText: String { args.search ?? "" }
    /// Mac session 画面要打开的会话（演示会话的 sessionID 与会话名相同）。
    static var sessionToOpen: String? { scene == "session" ? args.session : nil }
    /// 截图演示：编辑器载入后选中这一段（`起点:长度`，UTF-16）。
    static var editorSelection: NSRange? {
        guard let parts = args.select?.split(separator: ":").compactMap({ Int($0) }), parts.count == 2 else { return nil }
        return NSRange(location: parts[0], length: parts[1])
    }
    /// 挂上刻意的几何回写环（只给布局压力场景的检测器自检用）。
    static var injectsGeometryLoop: Bool { args.layoutOpts.geometryLoop }
    /// 项目页任务纸点"还有 N 条"的那条路（`debugExposesTaskFold`，看得见的那一页上的纸）。
    static var toggleTaskFold: () -> Void = {}
    /// 点 Cue 页头（Mac 是 Cue 栏头）开合面板的那条路（`debugExposesCuePanel`）。
    static var toggleCuePanel: () -> Void = {}
    #if os(iOS)
    /// 点窄屏侧栏额度钮的那条路（`debugExposesQuota`）。
    static var toggleQuota: () -> Void = {}
    /// 窗口那一层的模态浮出（`debugExposesModals`）：点外面关调的是开着那一个的 `close`。
    static weak var modals: ModalHost?
    #endif

    /// 第 `attempt` 次订阅项目目录（`Workspace.catalogAttempt`，从 0 起）是否按 `-CuePadCatalogFailure` 注入失败。
    static func injectCatalogFailure(attempt: Int) throws {
        guard let mode = args.catalogFailure else { return }
        if mode == "once" ? attempt == 0 : DebugArgs.isOn(mode) { throw InjectedFailure() }
    }

    struct InjectedFailure: LocalizedError {
        var errorDescription: String? { String(localized: "调试注入的读取失败（-CuePadCatalogFailure）", table: "Demo") }
    }

    static var preset: DebugHooks.Preset {
        var preset = DebugHooks.Preset()
        preset.searchText = searchText
        preset.editorSelection = editorSelection
        preset.toolsOpen = args.layoutOpts.toolsOpen
        preset.crashSheet = args.crashSheet
        preset.demoMac = args.demoMac
        // 流程演示与 Cue 的 sending 自己摆送达，不要演示 Mac 来接手，但话在路上要算同步通着（隔离库没有同步，不然是"没有在同步"）
        let inTransit = cueFlows || args.cueOpts.presence == "sending"
        preset.alwaysReachable = (preset.demoMac || inTransit) && args.sync == nil
        preset.modelMenu = args.layoutOpts.modelMenu
        preset.cueFocus = args.cueOpts.focus
        preset.reducesMotion = args.layoutOpts.reduceMotion
        preset.largestType = args.layoutOpts.largestType
        preset.highContrast = args.layoutOpts.highContrast
        preset.readerOn = args.layoutOpts.reader
        if args.layoutOpts.tasksOpen { preset.taskFold = TaskFold(showsAll: true, showsDone: true) }
        preset.showsDone = args.layoutOpts.showsDone
        preset.cueNow = args.cueOpts.now.flatMap { CueActivitySamples.named($0) ?? CueNowSamples.all[$0] }
        #if os(macOS)
        preset.hovered = hoverPoints
        preset.hoverSeconds = args.driveOpts.hoverSeconds
        #endif
        preset.quotaOpen = args.layoutOpts.quotaOpen
        preset.scheduleOpen = args.layoutOpts.scheduleOpen
        preset.helpOpen = args.layoutOpts.helpOpen
        preset.mergePreview = args.layoutOpts.mergePreview
        if args.libraryTab == "skills" { preset.libraryPane = .skills }
        #if os(iOS)
        preset.alertStatus = alertStatus
        // sessions、cuerows 画面看会话行：手机的会话列表在搜索页的会话一栏
        if args.searchScope == "sessions" || scene.map(["sessions", "cuerows"].contains) == true { preset.searchScope = .sessions }
        preset.cuePanelOpen = args.layoutOpts.cuePanel
        preset.quietAlerts = args.layoutOpts.quiet
        #endif
        return preset
    }
}
#endif
