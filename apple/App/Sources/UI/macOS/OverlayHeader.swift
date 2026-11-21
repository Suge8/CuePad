#if os(macOS)
import SwiftUI

@Observable
final class OverlayHeader {
    struct Content: Equatable {
        var page: Workspace.Overlay
        var title: String
        var detail = Dotted()
        var marks: EditedLine.Marks?
        var failed = false
        var help: String?
        var widest = Dotted()
    }

    private(set) var content: Content?

    func set(_ content: Content) {
        if self.content != content { self.content = content }
    }

    func clear(_ page: Workspace.Overlay) {
        if content?.page == page { content = nil }
    }
}

extension View {
    func overlayHeader(_ content: OverlayHeader.Content, in workspace: Workspace) -> some View {
        onChange(of: content, initial: true) { _, content in workspace.overlayHeader.set(content) }
            .onDisappear { workspace.overlayHeader.clear(content.page) }
    }
}

struct OverlayTitle: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let content = workspace.overlayHeader.content.flatMap { $0.page == workspace.overlay ? $0 : nil }
        VStack(spacing: 0) {
            Text(verbatim: content?.title ?? "").font(Typography.toolbarTitlePaired).foregroundStyle(palette.ink)
                .accessibilityAddTraits(.isHeader)
            ZStack {
                if let marks = content?.marks {
                    EditedLine(marks: EditedLine.Marks(edited: marks.edited, pinned: marks.pinned, save: .failed)).hidden()
                    EditedLine(marks: marks)
                } else {
                    line(content?.widest ?? Dotted()).hidden()
                    line(content?.detail ?? Dotted())
                }
            }
            .font(Typography.toolbarSubtitle)
            .foregroundStyle(content?.failed == true ? palette.failure : palette.ink3)
        }
        .lineLimit(1)
        .padding(.horizontal, Spacing.part)
        .frame(height: Self.height)
        .glass(in: .capsule)
        .help(content?.help ?? "")
        .accessibilityElement(children: .combine)
        .opacity(content == nil ? 0 : 1)
        .draggable(idea: content.flatMap { if case .card(let id) = $0.page { id } else { nil } })
    }

    private func line(_ text: Dotted) -> some View {
        HStack(spacing: Spacing.tight) {
            Image(.write).imageScale(.small).accessibilityHidden(true)
            Text(text)
        }
    }

    private static let height: CGFloat = 44
}
#endif
