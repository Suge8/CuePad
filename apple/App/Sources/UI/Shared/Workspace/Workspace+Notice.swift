import SwiftUI

/// 停留时长只在这里定：普通结果 `briefNotice`；带动作（撤销、归档）或出错 `lastingNotice`，要来得及读完再决定点不点。
/// 指针、键盘焦点在提示上时停表（`holdNotice`，提示条自己报），离开后接着数、至少再留 `graceNotice`；
/// 读屏开着时一直报停、不自动收：下一条顶掉它，或用读屏的"关闭"手势收。
extension Workspace {
    private static let briefNotice: Duration = .seconds(4)
    private static let lastingNotice: Duration = .seconds(8)
    private static let graceNotice: Duration = .seconds(2)

    /// 提示摆在哪只在这里定：会话条在（宽屏、开着、放得下）就在它底部，每一页同一处、不压主区；不在就盖在页头那一排，页头让开。
    var noticeInRail: Bool { layout == .wide && sidebarOpen && wideFits?.rail == true }
    var noticeOnHead: Bool { notice != nil && !noticeInRail }

    /// 收已经拼好的 `Dotted`；界面字面量走下面那个（进目录、按当前语言取字）。不给 `sound` 时出错的、带撤销的各有一声，只报结果的不出声（`Sound`）；声音只跟着看得见的提示响，由显示它的那一颗播（`NoticeCapsule`）。
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
        guard !held, let notice else { return }
        let due = max(noticeDue, .now + Self.graceNotice)
        // 只记身份：提示的动作可能攥着库（撤销），计时期间不跟着攥
        noticeTask = Task { [weak self, id = notice.id] in
            // 被停表或被下一条顶掉时 sleep 抛出取消：不收
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

    /// 不出提示、只是能撤的事（挪位置、置顶、完成）：结果就在眼前，不用再说一遍，⌘Z 撤得回。
    func undoable(_ what: LocalizedStringResource, _ run: @escaping Undo) {
        remember(NSObject(), String(localized: what)) { _ in try await run() }
    }

    /// 撤销记进窗口的系统撤销（"编辑 › 撤销归档"、⌘Z，手机与 iPad 的三指左滑、摇一摇），提示收走后照样撤得回；提示上的"撤销"是它看得见的入口。
    /// 隔了多久才撤由 Store 把关：之后又改过的不撤、报"已改过"，或只拨回那一次动过的（`CueStore.undo`、`unarchive(_:archivedAt:)`）。不记重做：撤回去的事再做一遍就是。
    private func remember(_ token: NSObject, _ what: String, _ run: @escaping @MainActor (Workspace) async throws -> Void) {
        guard let undoManager else { return }
        // 系统撤销不攥着主人：这一条在，它就得在，由闭包攥住
        undoManager.registerUndo(withTarget: token) { [weak self, token] _ in
            _ = token
            self?.undo(what, run)
        }
        undoManager.setActionName(what)
    }

    /// 撤了什么都说一声：撤的那件事可能不在眼前这一页。
    private func undo(_ what: String, _ run: @escaping @MainActor (Workspace) async throws -> Void) {
        notice = nil
        attempt {
            try await run(self)
            self.say("已撤销：\(what)", sound: .undo)
        }
    }
}

extension View {
    /// 根视图挂一次：把这个窗口的系统撤销交给工作区。
    func followsUndo(_ workspace: Workspace) -> some View { modifier(UndoFollower(workspace: workspace)) }
}

private struct UndoFollower: ViewModifier {
    let workspace: Workspace
    @Environment(\.undoManager) private var undoManager

    func body(content: Content) -> some View {
        content.onChange(of: undoManager, initial: true) { workspace.undoManager = undoManager }
    }
}
