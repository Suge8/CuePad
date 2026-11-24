import CueStore
import SwiftUI

#if DEBUG

enum DebugScene {
    nonisolated static var args: DebugArgs { DebugHooks.args }
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

#endif
