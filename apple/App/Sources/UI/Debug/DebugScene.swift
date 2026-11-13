import CueStore
import SwiftUI

#if DEBUG

/// 调试画面（只在 Debug 构建里，视觉验收、录屏、测量用）。启动参数的登记表是 `DebugArgs`（`DebugScene+Args*.swift`，字段注释即说明），画面的登记表是 `entries`（`DebugScene+Scenes.swift`）。
enum DebugScene {
    nonisolated static let args = DebugArgs.launch
    static var scene: String? { args.scene }
    static var windowSize: CGSize? {
        let parts = args.layoutOpts.windowSize?.split(separator: "x").compactMap { Double($0) } ?? []
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }
    static var cueNow = args.cueOpts.now.flatMap { CueActivitySamples.named($0) ?? CueNowSamples.all[$0] }
    static var sessionToOpen: String? { scene == "session" ? args.session : nil }
    static var injectsGeometryLoop: Bool { args.layoutOpts.geometryLoop }
    // 只在脚本起的实例里挂（`DebugHooks.scripted`）：全局攥着视图的闭包，连带它环境里的工作区与服务，测试宿主里每条用例的库都放不掉
    static var toggleTaskFold: () -> Void = {}
    static var toggleCuePanel: () -> Void = {}
    #if os(iOS)
    static var toggleQuota: () -> Void = {}
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
}

extension DebugHooks.Preset {
    init(_ args: DebugArgs) {
        searchText = args.search ?? ""
        if let parts = args.select?.split(separator: ":").compactMap({ Int($0) }), parts.count == 2 {
            editorSelection = NSRange(location: parts[0], length: parts[1])
        }
        toolsOpen = args.layoutOpts.toolsOpen
        stepOpen = args.layoutOpts.stepOpen
        crashSheet = args.crashSheet
        demoMac = args.demoMac
        // 流程演示与 Cue 的 sending 自己摆送达，不要演示 Mac 来接手，但话在路上要算同步通着（隔离库没有同步，不然是"没有在同步"）
        let inTransit = DebugScene.cueFlows || args.cueOpts.presence == "sending"
        alwaysReachable = (demoMac || inTransit) && args.sync == nil
        modelMenu = args.layoutOpts.modelMenu
        cueFocus = args.cueOpts.focus
        reducesMotion = args.layoutOpts.reduceMotion
        largestType = args.layoutOpts.largestType
        highContrast = args.layoutOpts.highContrast
        readerOn = args.layoutOpts.reader
        if args.layoutOpts.tasksOpen { taskFold = TaskFold(showsAll: true, showsDone: true) }
        showsDone = args.layoutOpts.showsDone
        #if os(macOS)
        hovered = DebugScene.hoverPoints
        hoverSeconds = args.driveOpts.hoverSeconds
        #endif
        quotaOpen = args.layoutOpts.quotaOpen
        scheduleOpen = args.layoutOpts.scheduleOpen
        mergePreview = args.layoutOpts.mergePreview
        cuePanelOpen = args.layoutOpts.cuePanel
        #if os(iOS)
        alertStatus = DebugScene.alertStatus
        // sessions、cuerows 画面看会话行：手机的会话列表在搜索页的会话一栏
        if args.searchScope == "sessions" || args.scene.map(["sessions", "cuerows"].contains) == true { searchScope = .sessions }
        quietAlerts = args.layoutOpts.quiet
        #endif
    }
}
#endif
