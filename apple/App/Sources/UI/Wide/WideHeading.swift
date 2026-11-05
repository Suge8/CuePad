import SwiftUI

/// 宽屏主区栏头的标题位：项目页写「项目 / 项目名」与介绍（`WideProjectHeading`），项目列表、更早、归档、回收站写页名；会话的栏头另是「项目 / 会话名」（`WideSessionTitle`）。
struct WideHeading: View {
    let title: String
    @Environment(\.palette) private var palette

    var body: some View {
        Text(verbatim: title).font(Typography.toolbarTitle).foregroundStyle(palette.ink).lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// 主栏开着项目页时栏头写「项目 / 项目名」（同会话栏头的「项目 / 会话名」，`WideSessionTitle`）：项目页是从项目列表进去的一页，点「项目」回列表；
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
                    Text(verbatim: "/").foregroundStyle(palette.ink3).accessibilityHidden(true)
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
    /// 宽屏栏头里空着的那截按住拖窗口（Mac；栏头在标题栏那一排，主区与 Cue 的托管视图不让标题栏自己拖，`ColumnHostingView`）。
    /// 挂在栏头那一排的底上：钮在上面照常点，钮之间的空处接拖动；双击同标题栏（缩放窗口）。iOS 上什么都不做。
    @ViewBuilder func windowDragArea() -> some View {
        #if os(macOS)
        background { Color.clear.contentShape(.rect).gesture(WindowDragGesture()).allowsWindowActivationEvents(true) }
        #else
        self
        #endif
    }
}
