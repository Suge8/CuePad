import CueStore
import SwiftUI

/// 卡住的会话就地处理的那一颗（`SessionRescue`）。
/// 原因卡上一直写着（线右端的状态词）；这颗是墨底反白的实心钮，一列卡里一眼找得到，不用红（红留给原因那几个字）。
struct BoardRescue: View {
    let session: SessionState
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            switch SessionRescue.of(session) {
            case .usage(let url): Link(destination: url) { face("管理用量") }
            case .retry: Button { workspace.retry(session) } label: { face("重试") }
            case .compact: Button { workspace.compact(session) } label: { face("现在压缩") }
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
            if let session, SessionRescue.of(session) != nil {
                BoardRescue(session: session).padding(.trailing, TaskMetrics.cardPadding).padding(.top, BoardCardMetrics.pad)
            }
        }
    }
}
