import CueStore
import SwiftUI

/// 胶囊里名字前面那一级：点它去上一级的页。
struct PaneCrumb {
    let title: String
    let action: () -> Void
}

extension PaneCrumb {
    /// 这样东西所在的项目：点它去那个项目的页。
    @MainActor init?(_ project: Project?, in workspace: Workspace) {
        guard let project else { return nil }
        self.init(title: project.shownName) { workspace.select(.project(project.id)) }
    }
}

/// 宽屏每一块顶上那颗胶囊，全 App 只此一种，都在这一块的左上角：上一级 / 名字 · 记号 · 这一块直接可点的钮 · 收起。
/// 名字是这一块的把手（`handle`）：拖进主区换位、并排（`WideDrop`）。这样东西自己的操作点名字后面的箭头出，Mac 上右键名字也出；
/// 名字自己不当菜单钮：Mac 的菜单按下就弹，按住拖不起来。iPad 的名字不挂长按菜单：长按是拎起，挂了就先弹菜单、挪了才拎得起。
struct PaneTitle<Items: View, Marks: View, Tools: View>: View {
    private let crumb: PaneCrumb?
    private let title: String
    private let handle: WideNavigation.Pane?
    private let close: (() -> Void)?
    private let menu: Items
    private let marks: Marks
    private let tools: Tools
    @Environment(\.wideWindowID) private var windowID
    @Environment(\.palette) private var palette

    init(
        crumb: PaneCrumb? = nil, title: String, handle: WideNavigation.Pane? = nil, close: (() -> Void)? = nil,
        @ViewBuilder menu: () -> Items = { EmptyView() }, @ViewBuilder marks: () -> Marks = { EmptyView() }, @ViewBuilder tools: () -> Tools = { EmptyView() }
    ) {
        self.crumb = crumb
        self.title = title
        self.handle = handle
        self.close = close
        self.menu = menu()
        self.marks = marks()
        self.tools = tools()
    }

    private var opens: Bool { Items.self != EmptyView.self }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: Spacing.glyph) {
                if let crumb {
                    Button(action: crumb.action) { Text(verbatim: crumb.title).lineLimit(1) }
                        .buttonStyle(PressStyle(.inline))
                        .foregroundStyle(palette.ink3)
                    Text(verbatim: "/").foregroundStyle(palette.ink3).fixedSize().readerHidden(true)
                }
                name
                if opens {
                    Menu { menu.labelStyle(.titleAndIcon) } label: {
                        Chevron(.expand).foregroundStyle(palette.ink3)
                            .padding(.horizontal, Spacing.tight).frame(height: Chrome.control).contentShape(.rect)
                    }
                    #if os(macOS)
                    .menuStyle(.button).menuIndicator(.hidden).fixedSize()
                    #endif
                    .buttonStyle(PressStyle(.inline))
                    .padding(.horizontal, -Spacing.tight)
                    .accessibilityLabel(Text("\(title) 的操作"))
                }
                marks
            }
            .padding(.trailing, Spacing.block - PaneClose.inset)
            HStack(spacing: 0) { tools }.labelStyle(.iconOnly).buttonStyle(PaneToolStyle())
            if let close { PaneClose(action: close) }
        }
        .font(Typography.toolbarTitle)
        .padding(.leading, Spacing.block)
        .padding(.trailing, PaneClose.inset)
        .frame(height: Chrome.control)
        .glass(in: .capsule)
    }

    @ViewBuilder private var name: some View {
        if let handle, let windowID, let column = DraggedColumn(windowID: windowID, handle) {
            #if os(iOS)
            WideTitleDrag(title: title, column: column, pane: handle).layoutPriority(1)
            #else
            let grip = label.overlay { PaneGrip(title: title, column: column) }
            if opens { grip.contextMenu { menu } } else { grip }
            #endif
        } else {
            label
        }
    }

    private var label: some View {
        Text(verbatim: title).foregroundStyle(palette.ink).lineLimit(1).accessibilityAddTraits(.isHeader)
    }
}

/// 胶囊里的图标钮：钮、点开菜单的钮同一个大小，悬停底是一个圆、不出胶囊的边。
struct PaneToolStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(PaneToolFace()).modifier(PressFeedback(pressed: configuration.isPressed, kind: .control))
    }
}

private struct PaneToolFace: ViewModifier {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.font(Glyph.control).foregroundStyle(isEnabled ? palette.ink2 : palette.ink3)
            .frame(width: PaneClose.side, height: PaneClose.side)
            .contentShape(.circle)
    }
}

/// 一块最顶那一排：胶囊在左上角，这一块直接可点的钮挨着它，空着的那截按住拖窗口。
struct PaneHead<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.headInset) private var inset

    var body: some View {
        HStack(spacing: Spacing.item) {
            content
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .padding(inset).frame(height: Chrome.band)
        .windowDragArea()
    }
}

extension Workspace {
    /// 并排着：每一块的胶囊都带收起。单独一块的会话与页不带（在会话条上换）。
    var isSplit: Bool { panes.count > 1 }
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

struct PaneClose: View {
    let action: () -> Void
    @Environment(\.palette) private var palette

    static let inset = Spacing.tight
    static var side: CGFloat { Chrome.control - 2 * inset }

    var body: some View {
        Button(action: action) {
            Image(.close).font(Glyph.small).foregroundStyle(palette.ink3)
                .frame(width: Self.side, height: Self.side)
                .contentShape(.circle)
        }
        .buttonStyle(PressStyle(.control))
        #if os(iOS)
        .contentShape(.hoverEffect, .circle)
        .hoverEffect(.highlight)
        #endif
        .help(Text("收起"))
        .accessibilityLabel(Text("收起"))
    }
}

/// 胶囊里一颗开关着的钮（活预览、并排）：开着时图标是签名色、垫一块选中底。
struct HeadTool: View {
    let label: LocalizedStringResource
    let icon: Icon
    var on = false
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) { Image(icon).foregroundStyle(on ? palette.signature : palette.ink2) }
            .toggledOn(on)
            .help(Text(label))
            .accessibilityLabel(Text(label))
            .accessibilityAddTraits(on ? .isSelected : [])
    }
}

extension EnvironmentValues {
    @Entry var headInset = EdgeInsets(top: 0, leading: Spacing.page, bottom: 0, trailing: Spacing.page)
    @Entry var underCue: CGFloat = 0
}

/// 点开盖在页上的规则、技能文件的栏头。名字后面那一行垫着最长的状态字：存着、存完来回换时胶囊不变宽。
struct LibraryFileHead: View {
    let file: LibraryFile
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let library = workspace.library
        let draft = workspace.draft(of: file, in: library)
        PaneHead {
            PaneTitle(title: workspace.fileTitle(file, in: library), close: { workspace.close(.library(file)) }, marks: {
                ZStack(alignment: .leading) {
                    line(Dotted(library?.fileName(file), FileDraft.longestShownState)).hidden()
                    line(library?.detail(of: file, draft: draft) ?? Dotted())
                }
                .font(Typography.toolbarSubtitle)
                .foregroundStyle(draft?.state == .failed ? palette.failure : palette.ink3)
            }, tools: {
                #if os(iOS)
                HeadTool(label: "发往 Mac", icon: .send) { if let draft { Task { await draft.send() } } }
                    .disabled(!(draft?.dirty ?? false) || draft?.state == .saving || draft?.conflicted == true)
                #endif
            })
            .help(library?.file(file).flatMap { library?.shown($0.textPath) } ?? "")
        }
    }

    private func line(_ text: Dotted) -> some View {
        HStack(spacing: Spacing.tight) {
            Image(.write).imageScale(.small).readerHidden(true)
            Text(text).lineLimit(1)
        }
    }
}
