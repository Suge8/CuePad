#if DEBUG
import SwiftUI

struct DebugSceneEntry {
    let names: [String]
    var prepare: (@MainActor (Workspace, UUID?) async throws -> Void)?
    var overlay: (@MainActor (Workspace) -> AnyView)?
    #if os(macOS)
    var stage: (@MainActor (Workspace) -> AnyView)?
    #endif

    typealias Prepare = @MainActor (Workspace, UUID?) async throws -> Void
    typealias Overlay = @MainActor (Workspace) -> AnyView

    #if os(macOS)
    init(_ names: String..., prepare: Prepare? = nil, overlay: Overlay? = nil, stage: Overlay? = nil) {
        self.names = names
        self.prepare = prepare
        self.overlay = overlay
        self.stage = stage
    }
    #else
    init(_ names: String..., prepare: Prepare? = nil, overlay: Overlay? = nil) {
        self.names = names
        self.prepare = prepare
        self.overlay = overlay
    }
    #endif
}

extension DebugScene {
    static let entries: [String: DebugSceneEntry] = {
        var all: [DebugSceneEntry] = [
            .shelf, .bins, .project, .search, .progress, .sessions, .task, .session, .newSession,
            .library, .editor, .settings, .cue, .cueRows, .stateIcons, .tokens, .rail,
        ]
        #if os(macOS)
        all += [.agentSetup, .connected, .update, .menuBar, .wallGap, .select]
        #else
        all += [.cuePanel, .sheets]
        #endif
        return Dictionary(all.flatMap { entry in entry.names.map { ($0, entry) } }, uniquingKeysWith: { _, _ in fatalError("画面名登记了两次") })
    }()

    static var entry: DebugSceneEntry? { scene.flatMap { entries[$0] } }
}
#endif
