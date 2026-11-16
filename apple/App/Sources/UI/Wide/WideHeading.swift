import SwiftUI

struct WideHeading: View {
    let title: String
    @Environment(\.palette) private var palette

    var body: some View {
        Text(verbatim: title).font(Typography.toolbarTitle).foregroundStyle(palette.ink).lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// 项目页的栏头：回项目列表的"项目"、项目名（点开是项目自己的操作，`ProjectActions`），紧跟着文件夹与规则两颗图标钮（`ProjectHeadTools`）。
/// 读内存里的项目目录（`Workspace.catalog`），不另订阅。
struct WideProjectHeading: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        if case .project(let id) = workspace.mainRoute, let project = workspace.catalog?.project(id) {
            HStack(spacing: 0) {
                Button { workspace.select(.shelf) } label: { Text("项目").modifier(HeadingPiece()) }
                    .foregroundStyle(palette.ink3)
                Text(verbatim: "/").foregroundStyle(palette.ink3).readerHidden(true)
                Menu { ProjectActions(project: project, folders: false).labelStyle(.titleAndIcon) } label: {
                    HStack(spacing: Spacing.tight) {
                        Text(verbatim: project.shownName).foregroundStyle(palette.ink).lineLimit(1)
                        Chevron(.expand).foregroundStyle(palette.ink3)
                    }
                    .modifier(HeadingPiece())
                }
                #if os(macOS)
                .menuStyle(.button).menuIndicator(.hidden)
                #endif
                .accessibilityLabel(project.shownName)
                .accessibilityHint("置顶、编辑名称与图标")
                .accessibilityAddTraits(.isHeader)
                HStack(spacing: 0) { ProjectHeadTools(project: project) }
                    .labelStyle(.iconOnly)
                    .imageScale(.large)
                    .buttonStyle(ControlButtonStyle(kind: .icon))
            }
            .buttonStyle(PressStyle(.button))
            // 第一块的字仍与下面的内容左对齐：悬停的底向左宽出去
            .padding(.leading, -HeadingPiece.inset)
            .font(Typography.toolbarTitle)
            .accessibilityElement(children: .contain)
        }
    }
}

/// 栏头里能点的字：悬停的底与旁边的图标钮（`ControlButtonStyle(kind: .icon)`）同高，一排里停到哪颗都是一样大的一块。
private struct HeadingPiece: ViewModifier {
    static let inset = Spacing.item

    func body(content: Content) -> some View {
        content.padding(.horizontal, Self.inset).frame(height: ControlSize.regular.height).contentShape(.capsule)
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
