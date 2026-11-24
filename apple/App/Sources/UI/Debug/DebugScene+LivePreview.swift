#if os(macOS) && DEBUG
import CueStore
import Foundation

extension DebugScene {
    /// `-CuePadLivePreview`：摆出左边会话、右半开着活预览的画面（`LayoutArgs.livePreview`）；`-CuePadLivePick` 接着开点选。
    /// 网页载完（或认定连不上）、点选摆好才算就绪：页面里的东西不在就绪的判断里，不拖着就会拍到半截。
    static func openLivePreviewIfAsked(_ workspace: Workspace) {
        guard let address = args.layoutOpts.livePreview else { return }
        workspace.toggleLivePreview()
        guard let session = workspace.liveSession else { return }
        if ["window", "remote"].contains(args.layoutOpts.liveViewport) { workspace.liveFill = .init(session: session.id, remote: args.layoutOpts.liveViewport == "remote") }
        guard address != "blank", workspace.typeLive(address, for: session.id), let preview = workspace.livePreviews[session.id] else { return }
        if args.layoutOpts.liveViewport == "phone" { preview.viewport = .phone }
        holdingReady("活预览载入") {
            while [.idle, .live].contains(preview.phase) && !preview.revealed { await Task.wait(for: .milliseconds(100)) }
            await Task.wait(for: .milliseconds(400))
            if let query = args.layoutOpts.livePick, preview.phase == .live { await pick(query, in: preview, workspace: workspace) }
        }
    }

    private static func pick(_ query: String, in preview: LivePreview, workspace: Workspace) async {
        workspace.pickElement()
        let commit = args.layoutOpts.livePickCommit
        let action = commit ? "pick" : "hover"
        let call = "const handle = window[Symbol.for('cuepad.pick')]; if (!handle) return false; handle.\(action)(query); return true"
        while (try? await preview.run(call, arguments: ["query": query])) as? Bool != true {
            await Task.wait(for: .milliseconds(50))
        }
        while commit && preview.picking { await Task.wait(for: .milliseconds(50)) }
    }
}
#endif
