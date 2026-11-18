import SwiftUI

struct WideHeading: View {
    let title: String
    @Environment(\.palette) private var palette

    var body: some View {
        Text(verbatim: title).font(Typography.toolbarTitle).foregroundStyle(palette.ink).lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// 只一行，同会话页的栏头（`WideSessionTitle`）：换页时名字不上下挪。项目的一句介绍在页里那一行（`ProjectIntroLine`）。
struct WideProjectHeading: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        if case .project(let id) = workspace.mainRoute, let project = workspace.catalog?.project(id) {
            HStack(spacing: Spacing.glyph) {
                Button("项目") { workspace.select(.shelf) }
                    .buttonStyle(PressStyle(.inline))
                    .foregroundStyle(palette.ink3)
                Text(verbatim: "/").foregroundStyle(palette.ink3).readerHidden(true)
                Text(verbatim: project.shownName).foregroundStyle(palette.ink).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
            .font(Typography.toolbarTitle)
            .accessibilityElement(children: .contain)
        }
    }
}

extension View {
    /// 栏头在标题栏那一排，主区与 Cue 的托管视图不让标题栏自己拖（`ColumnHostingView`），空着的那截要按住拖窗口就自己挂；双击同标题栏（缩放窗口）。iOS 上什么都不做。
    @ViewBuilder func windowDragArea() -> some View {
        #if os(macOS)
        background { Color.clear.contentShape(.rect).gesture(WindowDragGesture()).allowsWindowActivationEvents(true) }
        #else
        self
        #endif
    }
}
