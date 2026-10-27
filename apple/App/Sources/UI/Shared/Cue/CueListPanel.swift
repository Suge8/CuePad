import SwiftUI

/// Cue 的两张清单弹层（记忆 `CueMemoryPage`、定时 `CueSchedulePage`）共用的壳：Mac 是 480 宽的窗口内浮层，手机是整屏 sheet。
/// 顶上不写标题（`title` 只给读屏与多任务），右上一颗问号，点开一句说明；底部浮着玻璃输入胶囊，列表从它后面透过；空时正中是空态。
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
                .padding(.bottom, 12)
        }
        .scrollEdgeEffectHidden()
        .overlay { if isEmpty { empty.padding(20) } }
        // 滚动区止于胶囊半高处，胶囊下半截伸出滚动区：内容只从胶囊背后滚过，不在它下面与圆角外露出被面板下沿切掉的半行
        .safeAreaInset(edge: .bottom, spacing: 0) {
            field
                .padding(.horizontal, 18)
                .glass(in: .rect(cornerRadius: CueListMetrics.field / 2, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, -CueListMetrics.field / 2)
        }
        .padding(.bottom, CueListMetrics.fieldBottom + CueListMetrics.field / 2)
    }

    #if os(macOS)
    var body: some View {
        list
            // 右上的问号与关闭占着一排：第一行从它们下面起，滚动条照旧到顶
            .safeAreaPadding(.top, CueListMetrics.top)
            .contentMargins(.top, -CueListMetrics.top, for: .scrollIndicators)
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 6) {
                    CueListHelp(text: help)
                    PanelCloseButton()
                }
                .padding(12)
            }
            .frame(width: 480).frame(maxHeight: 600)
            .background(palette.desk)
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
                    ToolbarItem(placement: .primaryAction) { CueListHelp(text: help) }
                }
        }
        .presentationDetents([.large])
    }
    #endif
}

/// 右上那颗问号：点开一句说明，从它长出的气泡里。
private struct CueListHelp: View {
    let text: String
    @State private var open = false
    @Environment(\.palette) private var palette

    var body: some View {
        Button("说明", icon: .help) { open.toggle() }
            #if os(macOS)
            .labelStyle(.iconOnly).font(Typography.meta.weight(.semibold)).foregroundStyle(palette.ink2)
            .frame(width: 26, height: 26).background(palette.fill, in: .circle).contentShape(.circle)
            .buttonStyle(PressStyle())
            #endif
            .popover(isPresented: $open, arrowEdge: .top) {
                Text(verbatim: text)
                    .font(Typography.secondary).foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 260, alignment: .leading)
                    .padding(16)
                    .presentationCompactAdaptation(.popover)
            }
    }
}

/// 清单里的一行：内容占满宽度；两个动作手机上在右滑、左滑，菜单与读屏另有复制；菜单抬头与读屏另说 `meta`（什么时候、谁说的）。
/// Mac 右键出菜单，指针停在行上时铺行的淡底（`RowStyle`）、右下角露出两颗小钮。
struct CueListRow<Content: View>: View {
    let label: String
    var meta: Dotted
    let copy: RowAction
    /// 手机上右滑的那个
    let leading: RowAction
    /// 删的那个：手机上左滑
    let trailing: RowAction
    @ViewBuilder let content: Content
    @Environment(\.palette) private var palette

    private var actions: [RowAction] { [leading, trailing] }
    private var menu: some View {
        Section(meta.visible) { RowActionButtons(actions: [copy] + actions) }
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
            .contentShape(.contextMenuPreview, .rect(cornerRadius: CueListMetrics.radius, style: .continuous))
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
/// 指针停在行上时右下角浮出的两个动作（`hoverReveal`）。
private struct CueListHoverActions: View {
    let actions: [RowAction]
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 2) {
            ForEach(actions.keyed, id: \.key) { item in
                Button(item.action.title, icon: item.action.icon, action: item.action.run)
                    .labelStyle(.iconOnly)
                    .font(Typography.meta.weight(.medium))
                    .foregroundStyle(item.action.tone == .destructive ? palette.failure : palette.ink2)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
                    .buttonStyle(PressStyle(.button))
                    .help(item.action.title)
            }
        }
        .padding(.leading, 4)
    }
}
#endif

/// 组头：小号、第三档墨，可带一枚图标；上面空出一段把组分开。
struct CueListGroupTitle: View {
    let title: String
    var icon: Icon?

    var body: some View {
        SectionLabel(text: Dotted(title), icon: icon).padding(.horizontal, CueListMetrics.inset).padding(.top, 20).padding(.bottom, 2)
    }
}

/// 页边距（Mac 的行底向两边伸出 `RowMetrics.bleed`，边距要盖住它）、行的内边距、手机长按预览的圆角、输入胶囊的高与离底。
enum CueListMetrics {
    #if os(macOS)
    static let top: CGFloat = 48
    static let margin: CGFloat = 20
    static let inset: CGFloat = 0
    static let vertical: CGFloat = 7
    static let field: CGFloat = 44
    static let fieldBottom: CGFloat = 16
    #else
    static let margin: CGFloat = 4
    static let inset: CGFloat = 16
    static let vertical: CGFloat = 9
    static let radius: CGFloat = 16
    static let field: CGFloat = 50
    static let fieldBottom: CGFloat = 8
    #endif
}
