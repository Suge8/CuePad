import Foundation

/// 停留时长只在这里定：普通结果 `briefNotice`；带动作（撤销、归档）或出错 `lastingNotice`，要来得及读完再决定点不点。
/// 指针、键盘焦点在提示上时停表（`holdNotice`，提示条自己报）；读屏开着时一直报停、不自动收：下一条顶掉它，或用读屏的"关闭"手势收。
extension Workspace {
    private static let briefNotice: Duration = .seconds(4)
    private static let lastingNotice: Duration = .seconds(8)

    /// 收已经拼好的 `Dotted`；界面字面量走下面那个（进目录、按当前语言取字）。
    func say(_ text: Dotted, tone: Notice.Tone = .done, status: PiShown.Status? = nil, link: Route? = nil, action: NoticeAction? = nil) {
        notice = Notice(text: text, tone: tone, status: status, link: link, action: action)
        holdNotice(false)
    }

    func say(
        _ text: LocalizedStringResource, tone: Notice.Tone = .done, status: PiShown.Status? = nil, link: Route? = nil, action: NoticeAction? = nil
    ) {
        say(Dotted(String(localized: text)), tone: tone, status: status, link: link, action: action)
    }

    func fail(_ error: any Error) {
        say(Dotted(error.localizedDescription), tone: .failure)
    }

    func holdNotice(_ held: Bool) {
        noticeTask?.cancel()
        guard !held, let notice else { return }
        let duration = notice.action != nil || notice.isError ? Self.lastingNotice : Self.briefNotice
        // 只记身份：提示的动作可能攥着库（撤销），计时期间不跟着攥
        noticeTask = Task { [weak self, id = notice.id] in
            // 被停表或被下一条顶掉时 sleep 抛出取消：不收
            guard (try? await Task.sleep(for: duration)) != nil, self?.notice?.id == id else { return }
            self?.notice = nil
        }
    }
}
