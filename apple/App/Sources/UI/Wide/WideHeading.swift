import SwiftUI

struct WideHeading: View {
    let title: String
    @Environment(\.palette) private var palette

    var body: some View {
        Text(verbatim: title).font(Typography.toolbarTitle).foregroundStyle(palette.ink).lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

struct WideProjectHeading: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        if case .project(let id) = workspace.mainRoute, let project = workspace.catalog?.project(id) {
            HStack(spacing: 0) {
                ShelfCrumb()
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
            .padding(.leading, -HeadingPiece.inset)
            .font(Typography.toolbarTitle)
            .accessibilityElement(children: .contain)
        }
    }
}

struct WidePlaceHeading<Tools: View>: View {
    let title: String
    @ViewBuilder var tools: Tools
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            ShelfCrumb()
            Text(verbatim: title).foregroundStyle(palette.ink).lineLimit(1).modifier(HeadingPiece())
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 0) { tools }
                .labelStyle(.iconOnly)
                .imageScale(.large)
                .buttonStyle(ControlButtonStyle(kind: .icon))
        }
        .buttonStyle(PressStyle(.button))
        .padding(.leading, -HeadingPiece.inset)
        .font(Typography.toolbarTitle)
        .accessibilityElement(children: .contain)
    }
}

private struct ShelfCrumb: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        Button { workspace.select(.shelf) } label: { Text("项目").modifier(HeadingPiece()) }
            .foregroundStyle(palette.ink3)
        Text(verbatim: "/").foregroundStyle(palette.ink3).readerHidden(true)
    }
}

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
