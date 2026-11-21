import SwiftUI

struct CueListPanel<Rows: View, Field: View, Empty: View>: View {
    let title: String
    let help: String
    let isEmpty: Bool
    @ViewBuilder let rows: Rows
    @ViewBuilder let field: Field
    @ViewBuilder let empty: Empty
    @Environment(\.closePanel) private var close
    @Environment(\.palette) private var palette

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) { rows }
                .padding(.horizontal, CueListMetrics.margin)
                .padding(.bottom, Spacing.group)
        }
        .scrollEdgeEffectHidden()
        .overlay { if isEmpty { empty.padding(Spacing.panel) } }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            field
                .padding(.horizontal, Spacing.block)
                .containerShape(.rect(cornerRadius: Radius.field))
                .glass(in: .rect(cornerRadius: Radius.field))
                .padding(.horizontal, Spacing.block)
                .padding(.bottom, -CueListMetrics.field / 2)
        }
        .padding(.bottom, CueListMetrics.fieldBottom + CueListMetrics.field / 2)
    }

    #if os(macOS)
    var body: some View {
        list
            .safeAreaPadding(.top, CueListMetrics.top)
            .contentMargins(.top, -CueListMetrics.top, for: .scrollIndicators)
            .overlay(alignment: .topTrailing) {
                HStack(spacing: Spacing.item) {
                    HelpButton { CueListHelp(text: help) }
                    PanelCloseButton()
                }
                .padding(Spacing.group)
            }
            .frame(width: 480).frame(maxHeight: 600)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
    }
    #else
    var body: some View {
        NavigationStack {
            list
                .background(palette.desk)
                .navigationTitle(title)
                // 标题只给读屏与多任务，顶上不写：移除标题项只去掉小标题，大标题还要靠 inline 才不出现
                .toolbar(removing: .title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭", icon: .close, role: .cancel) { close() } }
                    ToolbarItem(placement: .primaryAction) { BarHelpButton { CueListHelp(text: help) } }
                }
        }
        .presentationDetents([.large])
    }
    #endif
}

private struct CueListHelp: View {
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        Text(verbatim: text)
            .font(Typography.secondary).foregroundStyle(palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: Self.width, alignment: .leading)
            .padding(Spacing.block)
    }

    private static let width: CGFloat = 260
}

struct CueListRow<Content: View>: View {
    let label: String
    var meta: Dotted
    let copy: RowAction
    let leading: RowAction
    let trailing: RowAction
    @ViewBuilder let content: Content
    @Environment(\.palette) private var palette

    private var actions: [RowAction] { [leading, trailing] }
    private var menu: some View {
        Section(meta.visible) { RowActionButtons(actions: [copy] + actions) }.menuIcons()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CueListMetrics.inset)
            .padding(.vertical, CueListMetrics.vertical)
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(label)
            .accessibilityValue(meta.spoken)
            #if os(iOS)
            // 长按抬起的预览与左右滑时露出的缝是这一行的快照：没有底色时抬起来是透明的一条。形状要写明：不写时 iOS 26 按所在容器取同心圆角
            .background(palette.desk, in: .rect)
            .contentShape(.contextMenuPreview, .rect(cornerRadius: Radius.card))
            .contextMenu { menu }
            .rowSwipes(RowSwipes(leading: [leading], trailing: [trailing]))
            #else
            .hoverReveal(.bottomTrailing) { CueListHoverActions(actions: actions) }
            .row()
            .contextMenu { menu }
            .accessibilityActions { RowActionButtons(actions: [copy] + actions) }
            #endif
    }
}

#if os(macOS)
private struct CueListHoverActions: View {
    let actions: [RowAction]
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.hair) {
            ForEach(actions.keyed, id: \.key) { item in
                Button(item.action.title, icon: item.action.icon, action: item.action.run)
                    .labelStyle(.iconOnly)
                    .font(Typography.meta.weight(.medium))
                    .foregroundStyle(item.action.tone == .destructive ? palette.failure : palette.ink2)
                    .frame(width: ControlSize.target, height: ControlSize.target)
                    .contentShape(.rect)
                    .buttonStyle(PressStyle(.button))
                    .help(item.action.title)
            }
        }
        .padding(.leading, Spacing.tight)
    }
}
#endif

enum CueListMetrics {
    #if os(macOS)
    static let top: CGFloat = 48
    static let margin = Spacing.panel
    static let inset: CGFloat = 0
    static let vertical: CGFloat = 7
    static let field: CGFloat = 44
    static let fieldBottom = Spacing.block
    #else
    static let margin = Spacing.tight
    static let inset = Spacing.inset
    static let vertical: CGFloat = 9
    static let field: CGFloat = 50
    static let fieldBottom = Spacing.item
    #endif
}
