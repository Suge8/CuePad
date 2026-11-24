import CueStore
import SwiftUI

struct BoardRescue: View {
    let session: SessionState
    var reserves = false
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            switch SessionRescue.of(session) {
            case .usage(let url): Link(destination: url) { face { Text("管理用量").font(Typography.label).padding(.horizontal, Spacing.group) } }
            case .retry: Button { workspace.retry(session) } label: { face { RescueDisc.glyph(.retry, "重试") } }
            case .compact: Button { workspace.compact(session) } label: { face { RescueDisc.glyph(.compacting, "现在压缩") } }
            case nil: EmptyView()
            }
        }
        .buttonStyle(PressStyle(.button))
        .fixedSize()
    }

    private func face(@ViewBuilder _ label: () -> some View) -> some View {
        label().rescueFace(palette)
            .frame(minWidth: reserves ? nil : TaskNextMark.target, minHeight: reserves ? nil : TaskNextMark.target, alignment: .trailing)
            .contentShape(.rect)
    }
}

struct RescueDisc: View {
    let icon: Icon
    let title: LocalizedStringResource
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) { Self.glyph(icon, title).rescueFace(palette).padding(Self.reach).contentShape(.rect) }
            .buttonStyle(PressStyle(.button))
            .padding(-Self.reach)
    }

    static func glyph(_ icon: Icon, _ title: LocalizedStringResource) -> some View {
        Label(title, icon: icon).labelStyle(.iconOnly).font(font).frame(width: TaskNextMark.disc).help(Text(title))
    }

    private static let reach = (TaskNextMark.target - TaskNextMark.disc) / 2
    #if os(macOS)
    private static let font = Glyph.small
    #else
    private static let font = Typography.captionBold
    #endif
}

private extension View {
    func rescueFace(_ palette: Palette) -> some View {
        foregroundStyle(palette.ink).frame(height: TaskNextMark.disc).background(palette.fill, in: .capsule)
    }
}

extension View {
    func boardRescue(_ session: SessionState?) -> some View {
        overlay(alignment: .bottomTrailing) {
            if let session, SessionRescue.of(session) != nil {
                BoardRescue(session: session).padding(.trailing, TaskMetrics.cardPadding)
                    .offset(y: (TaskNextMark.target - BoardCardMetrics.vitals) / 2 - BoardCardMetrics.pad)
            }
        }
    }
}
