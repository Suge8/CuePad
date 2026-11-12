import CueStore
import SwiftUI

/// 卡住的会话就地处理的那一颗：额度用完去管理用量，出错的重试，上下文快满的压缩（规则同会话页的 `FailureDock`、`ContextGauge`）。
/// 原因卡上一直写着（线右端的状态词）；这颗是墨底反白的实心钮，一列卡里一眼找得到，不用红（红留给原因那几个字）。
struct BoardRescue: View {
    let session: SessionState
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    enum Kind { case usage(URL), retry, compact }

    static func kind(of session: SessionState) -> Kind? {
        if let url = session.usageURL { return .usage(url) }
        if session.canRetry { return .retry }
        if session.context.flatMap(ContextMeter.init)?.level == .critical { return .compact }
        return nil
    }

    var body: some View {
        Group {
            switch Self.kind(of: session) {
            case .usage(let url): Link(destination: url) { face("管理用量") }
            case .retry: Button { workspace.retry(session) } label: { face("重试") }
            case .compact: Button { workspace.speak("/compact", to: .session(session, mode: .command)) } label: { face("现在压缩") }
            case nil: EmptyView()
            }
        }
        .buttonStyle(PressStyle(.button))
        .fixedSize()
    }

    private func face(_ title: LocalizedStringKey) -> some View {
        Text(title).font(Typography.label).foregroundStyle(palette.desk)
            .padding(.horizontal, Spacing.group).frame(height: ControlSize.inline.height)
            .background(palette.ink, in: .capsule).contentShape(.capsule)
    }
}

extension View {
    /// 浮在卡的右上角、不放进卡里：会话卡整张是一颗按钮（`BoardLink`），钮里不套钮。
    func boardRescue(_ session: SessionState?) -> some View {
        overlay(alignment: .topTrailing) {
            if let session, BoardRescue.kind(of: session) != nil {
                BoardRescue(session: session).padding(.trailing, TaskMetrics.cardPadding).padding(.top, BoardCardMetrics.pad)
            }
        }
    }
}
