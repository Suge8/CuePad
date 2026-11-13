#if DEBUG
import CueStore
import Foundation

extension DebugSceneEntry {
    /// session：整页打开 `-CuePadSession <会话名>`（iOS 默认 homepage；`-CuePadNotify YES` 走点锁屏通知的那条路进去；`-CuePadStream YES` 像真 Agent 一轮一轮追加）。
    /// 配 `-CuePadDemo YES` 写入 Mac 同步来的演示会话（`DebugScene+SessionDemo.swift`）；长对话见 `DebugScene+LongChat.swift`。
    /// send（iOS）：从卡片"发到 Mac"先选会话；给了 `-CuePadSession` 就当已选好，直接进它的近况页（卡片预填在回复框里）；
    /// 给了 `-CuePadTask <标题开头>` 是点那条任务的"开始"（交给新会话时带用哪家、哪个模型的那一排）。
    static let session = DebugSceneEntry("session", "send") { workspace, project in
        try await DebugScene.openSession(workspace, project: project)
    }
}

extension DebugScene {
    fileprivate static func openSession(_ workspace: Workspace, project: UUID?) async throws {
        let store = workspace.services.store
        #if os(macOS)
        await seedDemo(workspace.services)
        if let id = sessionToOpen {
            workspace.show(.session(id))
            if args.driveOpts.stream { Task { await stream(id, store: store) } }
        }
        #else
        if scene == "send" {
            if let prefix = args.task {
                if let task = try await store.tasks(.todo, .inProgress).flatMap(\.tasks).first(where: { $0.title.hasPrefix(prefix) }) {
                    workspace.handOff(task)
                    // `-CuePadLaunch YES`：已经替你交给新会话（看发出后的进度写在同一个输入框上）
                    if args.launch, let outbox = workspace.outbox {
                        workspace.launchHandOff(outbox, opening: nil, plan: try await store.handOffPlan(task.id, host: nil, fresh: true))
                    }
                }
                return
            }
            try await openCard(workspace, project: project)
            if let id = try await card(in: project ?? Project.defaultID, store: store), let card = try await store.card(id) {
                let outbox = Outbox(content: Outgoing.text(of: card), card: id, project: project)
                if let title = args.session, let session = try await demoSession(titled: title, store: store) {
                    let settings = workspace.services.settings
                    var reply = settings.replyDraft(for: session.id)
                    reply.attachments = [outbox]
                    settings.setReplyDraft(reply, for: session.id)
                    workspace.openSession(session.id, sessionID: session.sessionID)
                } else {
                    workspace.outbox = outbox
                }
            }
            return
        }
        let title = args.session ?? "homepage"
        if args.demo { await seedCue(workspace.services) }
        guard let session = try await demoSession(titled: title, store: store) else { return }
        if args.notify {
            workspace.open(DeepLink.session(session.id))
        } else {
            workspace.openSession(session.id, sessionID: session.sessionID)
        }
        if args.driveOpts.stream { Task { await stream(session.sessionID, store: store) } }
        #endif
    }
}
#endif
