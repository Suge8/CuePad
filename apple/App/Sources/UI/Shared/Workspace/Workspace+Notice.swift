import SwiftUI

extension Workspace {
    private static let briefNotice: Duration = .seconds(4)
    private static let lastingNotice: Duration = .seconds(8)
    private static let graceNotice: Duration = .seconds(2)

    var noticeInRail: Bool { layout == .wide && sidebarOpen && wideSizes?.railFits == true }
    var noticeOnHead: Bool { notice != nil && !noticeInRail }

    func say(
        _ text: Dotted, tone: Notice.Tone = .done, status: SessionShown.Status? = nil, link: Route? = nil, action: NoticeAction? = nil, sound: Sound? = nil
    ) {
        let sound = sound ?? (tone == .failure ? .fail : action?.undoes != nil ? .act : nil)
        let notice = Notice(text: text, tone: tone, status: status, link: link, action: action, sound: sound)
        self.notice = notice
        noticeDue = .now + (action != nil || notice.isError ? Self.lastingNotice : Self.briefNotice)
        if let action, let what = action.undoes { remember(action.token, what) { try await action.run($0) } }
        holdNotice(false)
    }

    func say(
        _ text: LocalizedStringResource, tone: Notice.Tone = .done, status: SessionShown.Status? = nil, link: Route? = nil, action: NoticeAction? = nil,
        sound: Sound? = nil
    ) {
        say(Dotted(String(localized: text)), tone: tone, status: status, link: link, action: action, sound: sound)
    }

    func fail(_ error: any Error) {
        say(Dotted(error.localizedDescription), tone: .failure)
    }

    func holdNotice(_ held: Bool) {
        noticeTask?.cancel()
        guard !held, let notice, notice.tone != .pick else { return }
        let due = max(noticeDue, .now + Self.graceNotice)
        noticeTask = Task { [weak self, id = notice.id] in
            guard (try? await Task.sleep(until: due)) != nil, self?.notice?.id == id else { return }
            self?.notice = nil
        }
    }

    /// 点了提示上的钮。撤销的那一条就是系统撤销最上面那条时走系统撤销，撤过的不留在"编辑 › 撤销"里；
    /// 其间又打过字（最上面是打字的那一步）就直接撤、把它那一条的内容拿掉：系统撤销只能从最上面撤，那里会剩一步空的。
    func run(_ action: NoticeAction) {
        guard let what = action.undoes else {
            notice = nil
            return attempt { try await action.run(self) }
        }
        if let undoManager, undoManager.canUndo, undoManager.undoActionName == what { return undoManager.undo() }
        undoManager?.removeAllActions(withTarget: action.token)
        undo(what) { try await action.run($0) }
    }

    func undoable(_ what: LocalizedStringResource, _ run: @escaping Undo) {
        remember(NSObject(), String(localized: what)) { _ in try await run() }
    }

    private func remember(_ token: NSObject, _ what: String, _ run: @escaping @MainActor (Workspace) async throws -> Void) {
        guard let undoManager else { return }
        // 系统撤销不攥着主人：这一条在，它就得在，由闭包攥住
        undoManager.registerUndo(withTarget: token) { [weak self, token] _ in
            _ = token
            self?.undo(what, run)
        }
        undoManager.setActionName(what)
    }

    private func undo(_ what: String, _ run: @escaping @MainActor (Workspace) async throws -> Void) {
        notice = nil
        attempt {
            try await run(self)
            self.say("已撤销：\(what)", sound: .undo)
        }
    }
}

extension View {
    func followsUndo(_ workspace: Workspace) -> some View { modifier(UndoFollower(workspace: workspace)) }
}

private struct UndoFollower: ViewModifier {
    let workspace: Workspace
    @Environment(\.undoManager) private var undoManager

    func body(content: Content) -> some View {
        content.onChange(of: undoManager, initial: true) { workspace.undoManager = undoManager }
    }
}
