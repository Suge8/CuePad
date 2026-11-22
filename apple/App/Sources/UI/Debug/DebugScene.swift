import CueStore
import SwiftUI

#if DEBUG

enum DebugScene {
    nonisolated static let args = DebugArgs.launch
    static var scene: String? { args.scene }
    static var windowSize: CGSize? {
        let parts = args.layoutOpts.windowSize?.split(separator: "x").compactMap { Double($0) } ?? []
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }
    static let pinned = Pinned()
    static var sessionToOpen: String? { scene == "session" ? args.session : nil }
    static var injectsGeometryLoop: Bool { args.layoutOpts.geometryLoop }
    static var toggleTaskFold: () -> Void = {}
    static var toggleCuePanel: () -> Void = {}
    #if os(iOS)
    static var toggleQuota: () -> Void = {}
    static weak var modals: ModalHost?
    #endif

    @Observable final class Pinned {
        var cueNow = args.cueOpts.now.flatMap { CueActivitySamples.named($0) ?? CueNowSamples.all[$0] }
    }

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
        let inTransit = DebugScene.cueFlows || args.cueOpts.presence == "sending"
        alwaysReachable = (demoMac || inTransit) && args.sync == nil
        modelMenu = args.layoutOpts.modelMenu
        cueFocus = args.cueOpts.focus
        reducesMotion = args.layoutOpts.reduceMotion
        reducesTransparency = args.layoutOpts.reduceTransparency
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
        cueSky = args.cueOpts.sky
        indexOpen = args.indexOpen.flatMap { ["leading": .leading, "trailing": .trailing][$0] }
        #if os(iOS)
        alertStatus = DebugScene.alertStatus
        searchListsSessions = args.searchScope == "sessions" || args.scene.map(["sessions", "cuerows"].contains) == true
        quietAlerts = args.layoutOpts.quiet
        #endif
    }
}
#endif
