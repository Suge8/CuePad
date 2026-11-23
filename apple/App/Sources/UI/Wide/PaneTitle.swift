import CueStore
import SwiftUI
import UniformTypeIdentifiers

/// 宽屏每一块顶上那颗胶囊，全 App 只此一种，都在这一块的左上角：上一级 / 名字 · 记号 · 收起。
/// 名字是这一块的把手（`handle`）：拖进主区换位、并排（`WideDrop`）。这样东西自己的操作点名字后面的箭头出，右键名字也出；
/// 名字自己不当菜单钮：Mac 的菜单按下就弹，按住拖不起来。
struct PaneTitle<Items: View, Marks: View>: View {
    struct Crumb {
        let title: String
        let action: () -> Void
    }

    var crumb: Crumb?
    let title: String
    var handle: WideNavigation.Pane?
    var close: (() -> Void)?
    @ViewBuilder var menu: Items
    @ViewBuilder var marks: Marks
    @Environment(\.wideWindowID) private var windowID
    @Environment(\.palette) private var palette

    private var opens: Bool { Items.self != EmptyView.self }

    var body: some View {
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
            if let close { PaneClose(action: close) }
        }
        .font(Typography.toolbarTitle)
        .padding(.leading, Spacing.block)
        .padding(.trailing, close == nil ? Spacing.block : PaneClose.inset)
        .frame(height: Chrome.control)
        .glass(in: .capsule)
    }

    @ViewBuilder private var name: some View {
        if let handle, let windowID {
            if opens { grip(handle, windowID).contextMenu { menu } } else { grip(handle, windowID) }
        } else {
            Text(verbatim: title).foregroundStyle(palette.ink).lineLimit(1).accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder private func grip(_ pane: WideNavigation.Pane, _ windowID: UUID) -> some View {
        #if os(iOS)
        switch pane {
        case .card(let id): WideTitleDrag(title: title, type: .cuepadCard, item: DraggedCard.idea(id), pane: pane)
        default: WideTitleDrag(title: title, type: DraggedColumn.type, item: DraggedColumn(windowID: windowID, pane), pane: pane)
        }
        #else
        let text = Text(verbatim: title).foregroundStyle(palette.ink).lineLimit(1).accessibilityAddTraits(.isHeader).contentShape(.rect)
        switch pane {
        case .card(let id): text.draggable(DraggedCard.idea(id))
        default: text.draggable(DraggedColumn(windowID: windowID, pane))
        }
        #endif
    }
}

extension PaneTitle where Items == EmptyView {
    init(crumb: Crumb? = nil, title: String, handle: WideNavigation.Pane? = nil, close: (() -> Void)? = nil, @ViewBuilder marks: () -> Marks) {
        self.init(crumb: crumb, title: title, handle: handle, close: close, menu: { EmptyView() }, marks: marks)
    }
}

extension PaneTitle where Items == EmptyView, Marks == EmptyView {
    init(crumb: Crumb? = nil, title: String, handle: WideNavigation.Pane? = nil, close: (() -> Void)? = nil) {
        self.init(crumb: crumb, title: title, handle: handle, close: close, menu: { EmptyView() }, marks: { EmptyView() })
    }
}

extension PaneTitle where Marks == EmptyView {
    init(crumb: Crumb? = nil, title: String, handle: WideNavigation.Pane? = nil, close: (() -> Void)? = nil, @ViewBuilder menu: () -> Items) {
        self.init(crumb: crumb, title: title, handle: handle, close: close, menu: menu, marks: { EmptyView() })
    }
}

extension PaneTitle.Crumb {
    /// 这样东西所在的项目：点它去那个项目的页。
    @MainActor init?(_ project: Project?, in workspace: Workspace) {
        guard let project else { return nil }
        self.init(title: project.shownName) { workspace.select(.project(project.id)) }
    }
}

extension DraggedColumn {
    @MainActor init(windowID: UUID, _ pane: WideNavigation.Pane) {
        self.init(windowID: windowID, session: pane.session.map { Session(recordID: $0.id, sessionID: $0.sessionID) })
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
    private static var side: CGFloat { Chrome.control - 2 * inset }

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

struct HeadTool: View {
    let label: LocalizedStringResource
    let icon: Icon
    var on = false
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) { Image(icon).foregroundStyle(on ? palette.signature : palette.ink2) }
            .buttonStyle(ControlButtonStyle(kind: .circular))
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
            })
            .help(library?.file(file).flatMap { library?.shown($0.textPath) } ?? "")
            #if os(iOS)
            HeadTool(label: "发往 Mac", icon: .send) { if let draft { Task { await draft.send() } } }
                .disabled(!(draft?.dirty ?? false) || draft?.state == .saving || draft?.conflicted == true)
            #endif
        }
    }

    private func line(_ text: Dotted) -> some View {
        HStack(spacing: Spacing.tight) {
            Image(.write).imageScale(.small).readerHidden(true)
            Text(text).lineLimit(1)
        }
    }
}
