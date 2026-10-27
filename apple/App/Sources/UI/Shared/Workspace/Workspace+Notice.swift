import Foundation

/// 提示条（`Notice`）：说一句，几秒后自己收起；失败也经这里说。
extension Workspace {
    static let noticeDuration: Duration = .seconds(2.4)

    /// 收已经拼好的 `Dotted`；界面字面量走下面那个（进目录、按当前语言取字）。
    func say(
        _ text: Dotted, tone: Notice.Tone = .done, status: PiShown.Status? = nil, link: Route? = nil, duration: Duration = Workspace.noticeDuration,
        action: NoticeAction? = nil
    ) {
        let notice = Notice(text: text, tone: tone, status: status, link: link, action: action)
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            if self?.notice == notice { self?.notice = nil }
        }
    }

    func say(
        _ text: LocalizedStringResource, tone: Notice.Tone = .done, status: PiShown.Status? = nil, link: Route? = nil,
        duration: Duration = Workspace.noticeDuration, action: NoticeAction? = nil
    ) {
        say(Dotted(String(localized: text)), tone: tone, status: status, link: link, duration: duration, action: action)
    }

    func fail(_ error: any Error) {
        say(Dotted(error.localizedDescription), tone: .failure)
    }
}
