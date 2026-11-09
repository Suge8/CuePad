import SwiftUI

struct WideHeading: View {
    let title: String
    @Environment(\.palette) private var palette

    var body: some View {
        Text(verbatim: title).font(Typography.toolbarTitle).foregroundStyle(palette.ink).lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// 第二行是项目的一句介绍（`Project.intro`；没写也占着这一行，栏头的字不上下跳）。读内存里的项目目录（`Workspace.catalog`），不另订阅；
/// 文件夹与"规则"留在页里那一行（`ProjectIntroLine` 的 `intro: false`）。Mac 编辑浮层开着时不写（浮层自己写是哪一份，`OverlayTitle`）。
struct WideProjectHeading: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        if !overlaid, case .project(let id) = workspace.mainRoute, let project = workspace.catalog?.project(id) {
            VStack(alignment: .leading, spacing: Spacing.hair) {
                HStack(spacing: Spacing.glyph) {
                    Button("项目") { workspace.select(.shelf) }
                        .buttonStyle(PressStyle(.inline))
                        .foregroundStyle(palette.ink3)
                    Text(verbatim: "/").foregroundStyle(palette.ink3).readerHidden(true)
                    Text(verbatim: project.shownName).foregroundStyle(palette.ink).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                }
                .font(Typography.toolbarTitle)
                Text(verbatim: project.intro?.nonEmpty ?? " ").font(Typography.toolbarSubtitle).foregroundStyle(palette.ink3).lineLimit(1)
                    .help(project.intro ?? "")
                    .readerHidden(project.intro?.nonEmpty == nil)
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var overlaid: Bool {
        #if os(macOS)
        workspace.overlay != nil
        #else
        false
        #endif
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
