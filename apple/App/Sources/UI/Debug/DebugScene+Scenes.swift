#if DEBUG
import SwiftUI

struct DebugSceneEntry {
    let names: [String]
    /// 数据就绪、主窗口出来之后摆画面；第二个参数是 `-CuePadProject` 打开的项目。
    var prepare: (@MainActor (Workspace, UUID?) async throws -> Void)?
    /// 盖在窗口根上的整页样板（总览、样张）。iOS 之后统一套 `withPalette()`，Mac 自己套。
    var overlay: (@MainActor (Workspace) -> AnyView)?
    #if os(macOS)
    /// 取代主窗口内容：另一扇窗（菜单栏面板、新会话表单）放进主窗口里拍。
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
    /// 全部画面。加画面：在 `Scenes/` 新建文件写一个 `DebugSceneEntry`，在这里登记一行。
    static let entries: [String: DebugSceneEntry] = {
        var all: [DebugSceneEntry] = [
            .shelf, .bins, .earlier, .project, .search, .progress, .sessions, .task, .session, .newSession,
            .library, .editor, .settings, .cue, .cueRows, .stateIcons, .rail,
        ]
        #if os(macOS)
        all += [.agentSetup, .connected, .updateWait, .menuBar, .wallGap, .select]
        #else
        all += [.cuePanel, .sheets]
        #endif
        return Dictionary(all.flatMap { entry in entry.names.map { ($0, entry) } }, uniquingKeysWith: { _, _ in fatalError("画面名登记了两次") })
    }()

    static var entry: DebugSceneEntry? { scene.flatMap { entries[$0] } }
}
#endif
