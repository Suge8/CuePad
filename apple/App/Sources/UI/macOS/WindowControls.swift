#if os(macOS)
import CueStore
import SwiftUI

/// 内容区工具栏最左：侧栏收起时的项目切换（紧跟在侧栏钮后面）。同一个工具栏项里增减（增删工具栏项会重排整条工具栏）。
/// 单独一个视图读侧栏开合：主窗口的视图体读了它，开合的那一帧就要重算整个窗口、重新提交整条工具栏。
struct SwitcherSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let collapsed = workspace.pages.sidebar == .detailOnly
        // 一直挂着（收起时才有宽度）：开合侧栏的那一刻不再现建全部项目的菜单。不用 disabled：环境一变整份菜单又要重算；
        // ⌘1–9 本来就由窗口快捷键（`WorkspaceShortcuts`）接，菜单里的只是提示
        // 玻璃与墨色字自己画，同右边的项目范围（`ProjectScopeMenu`）：交给工具栏画时，没焦点的窗口里字是停用的淡灰
        ProjectSwitcher(collapsed: collapsed)
            .menuStyle(.button).buttonStyle(ControlButtonStyle(kind: .glass))
            .padding(.trailing, Spacing.toolbarGap)
            .frame(width: collapsed ? nil : 0, alignment: .leading)
            .clipped()
            .opacity(collapsed ? 1 : 0)
            // 不跟着侧栏的动画变宽：工具栏项每帧变一次宽，整条工具栏就每帧重新约束一遍
            .animation(nil, value: collapsed)
            .accessibilityHidden(!collapsed)
    }
}

/// 开合侧栏（`MacPages.toggleSidebar`，⌃⌘S 同）。收起时侧栏的 Cue 名片看不见了：不在 Cue 页、Cue 有等你或新消息时钮角上带点（`CueDot`）。
struct SidebarToggle: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        // 点画在标签里：工具栏把"字 + 图标"的标签换成系统按钮，挂在按钮外面的会被丢掉
        Button { workspace.pages.toggleSidebar() } label: {
            Image(.sidebar).overlay(alignment: .topTrailing) {
                if workspace.pages.sidebar == .detailOnly, workspace.root != .cue { CueDot().offset(x: 5, y: -4) }
            }
        }
        .accessibilityLabel("侧栏")
        .help("显示或隐藏侧栏（⌃⌘S）")
    }
}

/// 打开、收起卡片只改动下面三处（收起按钮、编辑页图层、底部输入条的位置），各自读"打开的卡"：
/// 主窗口的视图体不读它，开合时不重算整个窗口、不重建整条工具栏。

/// 工具栏左上的"收起"：只在开着编辑页时有（Esc 同）。工具栏项常驻、只有里面的按钮出没（增删工具栏项会重建整条工具栏）；
/// 没有编辑页时它不占位置。
struct CloseButton: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if workspace.openCard != nil {
            Button { workspace.openCard = nil } label: {
                HStack(spacing: 4) {
                    Image(.back).font(.system(size: 13, weight: .semibold))
                    Text("收起")
                }
            }
            .buttonStyle(ControlButtonStyle(kind: .glass))
            .keyboardShortcut(.cancelAction)
            .help("收起（Esc）")
        }
    }
}

/// 工具栏左边、侧栏钮（与侧栏收起时的项目切换）之后：进展页两段的图标分段（`ProgressPanes`，同 iPhone 顶上那块玻璃里那一组），两段同一个位置。
/// 右沿报给看板段的列头（`MacPages.panesEdge`）：它下面的列头从它右边起，不压在分段下面。
struct PanesSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let shown = workspace.root == .progress
        ProgressControl { ProgressPanes(size: Self.side).padding(Self.inset).glass(in: .capsule) }
            // 两颗方钮连同边距：挂上之前空着的这一格同样大
            .frame(width: 2 * Self.side + 2 * Self.inset, height: Spacing.toolbarControl)
            .background { WindowEdge(\.maxX) { workspace.pages.panesEdge = $0 } }
            .opacity(shown ? 1 : 0).allowsHitTesting(shown).accessibilityHidden(!shown)
    }

    private static let inset: CGFloat = 3
    /// 一颗的边长：与工具栏的控件一样高。
    private static let side = Spacing.toolbarControl - inset * 2
}

/// 量这一块的一条边（`CGRect.minX`、`maxX`）在窗口里的横坐标：工具栏项与页面不在同一棵视图里，SwiftUI 的全局坐标对不上，按窗口坐标量。
/// 开合侧栏、拖侧栏的宽时挪的是外面的几层（工具栏项那一格），听这几层的框变了再量。
struct WindowEdge: NSViewRepresentable {
    let edge: KeyPath<CGRect, CGFloat>
    let report: (CGFloat) -> Void

    init(_ edge: KeyPath<CGRect, CGFloat>, report: @escaping (CGFloat) -> Void) {
        self.edge = edge
        self.report = report
    }

    func makeNSView(context: Context) -> Probe { Probe(edge: edge, report: report) }
    func updateNSView(_ probe: Probe, context: Context) { probe.report = report }

    final class Probe: NSView {
        let edge: KeyPath<CGRect, CGFloat>
        var report: (CGFloat) -> Void
        private var observers: [any NSObjectProtocol] = []
        private var last: CGFloat?

        init(edge: KeyPath<CGRect, CGFloat>, report: @escaping (CGFloat) -> Void) {
            self.edge = edge
            self.report = report
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = sequence(first: self as NSView, next: \.superview).map { view in
                NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.measure() }
                }
            }
            measure()
        }

        override func layout() {
            super.layout()
            measure()
        }

        private func measure() {
            guard window != nil else { return }
            let x = convert(bounds, to: nil)[keyPath: edge]
            guard x != last else { return }
            last = x
            // 不在布局的这一圈里改可观察的值
            DispatchQueue.main.async { [report] in report(x) }
        }
    }
}

/// 工具栏左边、两段分段之后：这一页的范围，进展页的会话段是项目范围（`ProjectScopeMenu`，`Workspace.projectScope`；看板段那一排是列头，范围在"⋯"里）。
/// 工具栏里的页面控件只有一条规矩（这一格、`PanesSlot`、`QuotaSlot`、`PageActionSlot`、`SearchSlot`、`PageMenuSlot` 都照它）：只放 Workspace 里已有的状态，主窗口里常驻、固定宽度、只换内容。
/// 工具栏项挂在主窗口上，读不到页面读的库，抄一份过来就是第二个事实源；工具栏项一增删整条重建（实测占进出会话页点击回合的一半，25fdb5fa、4fd371a4），
/// 一变尺寸整条重排、重算整窗的鼠标跟踪区（100～150ms，b9707fc5）。所以每页都在（只在进展页露的随它挂上，`ProgressControl`），别的页看不见、不卸下（换页时不现建整份项目菜单），
/// 项目名长了在这一格里截断，不撑宽它；状态归页面的（会话段的搜索、新会话表单读的这台 Mac 上有哪些 Agent）留在页里。
struct ScopeSlot: View {
    @Environment(Workspace.self) private var workspace

    static let width: CGFloat = 200

    var body: some View {
        let shown = workspace.showsSessionsBar
        // 随进展页挂上后一直挂着、别的页只是看不见：换页时不现建整份项目菜单
        ProgressControl { ProjectScopeMenu().frame(maxWidth: Self.width, alignment: .leading) }
            .opacity(shown ? 1 : 0).allowsHitTesting(shown).accessibilityHidden(!shown)
            .frame(width: Self.width, height: Spacing.toolbarControl, alignment: .leading)
    }
}

/// 工具栏右边、搜索之前：进展页会话段的额度环（额度是会话的，看板段不放）（`QuotaRings`，点它从环下长出明细的气泡 `QuotaDetail`）。额度是整个 App 的（`AppServices.accountQuotas`），
/// 不是哪一页读的库，照 `ScopeSlot` 的规矩常驻、固定宽度，别的页看不见。
struct QuotaSlot: View {
    @Environment(Workspace.self) private var workspace
    @State private var open = DebugHooks.preset.quotaOpen
    /// 收起的时刻：按在环上收起的，松开时不再打开（`PressPoint.reopens`）。
    @State private var closed: ContinuousClock.Instant?

    /// 三颗环（`QuotaRings` 至多三个账号）的宽。
    static let width: CGFloat = 92

    var body: some View {
        let shown = workspace.showsSessionsBar
        ProgressControl {
            QuotaRings(open: open, height: Spacing.toolbarControl) { open = !open && !PressPoint.reopens(closedAt: closed) }
                .glass(in: .capsule, interactive: true)
                .bubble(isPresented: $open) { QuotaDetail().padding(16) }
        }
        .onChange(of: open) { _, open in if !open { closed = .now } }
        .opacity(shown ? 1 : 0).allowsHitTesting(shown).accessibilityHidden(!shown)
        .frame(width: Self.width, height: Spacing.toolbarControl, alignment: .trailing)
    }
}

/// 进展页才露的工具栏控件（`PanesSlot`、`ScopeSlot`、`QuotaSlot`）：别的页上看不见、只占着固定的那一格。随进展页一起挂上——启动后空闲时进展页先挂上（`Prewarm`），
/// 或一打开就在进展页——之后一直挂着；挂上之前那一格空着，第一帧不建看不见的分段、项目菜单、玻璃与额度环。
private struct ProgressControl<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(Workspace.self) private var workspace
    @State private var mounted = false

    var body: some View {
        let due = workspace.mountedPages.contains(.progress)
        ZStack { if mounted || due { content } }
            .onChange(of: due, initial: true) { if $1 { mounted = true } }
    }
}

/// 工具栏右边、搜索之前：进展页会话段的"新会话"（弹出新会话的表单，`NewSessionPanel`，⌥⌘N 同）；看板段的新任务在"⋯"里。
/// 规矩同 `ScopeSlot`：每页都在、宽度不随页变，别的页看不见；宽度就是字宽（字不随页变），离左右两块玻璃都是 `toolbarGap`。
struct PageActionSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let shown = workspace.showsSessionsBar
        // 工具栏把"图标 + 字"的标签只画成图标：写明两样都要
        Button("新会话", icon: .add) { workspace.showsNewSession = true }
            .labelStyle(.titleAndIcon)
            .buttonStyle(ControlButtonStyle(kind: .glass))
            .help("开一个新的 Agent 会话（⌥⌘N）")
            .opacity(shown ? 1 : 0).allowsHitTesting(shown).accessibilityHidden(!shown)
            .fixedSize()
            .frame(height: Spacing.toolbarControl)
            .padding(.leading, Spacing.toolbarGap)
    }
}

/// 工具栏右边的搜索（⌘K 同）。进展页的看板上不在这里：那一排是列头，搜索收在"⋯"里（`PageMenuSlot`）；常驻、只是看不见（同 `ScopeSlot`）。
struct SearchSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let shown = !workspace.boardOwnsTopRow
        // 资料库读不出来时：搜索结果能打开卡片，是写入入口
        Button { workspace.searching.toggle() } label: { Image(.search) }
            .buttonStyle(ControlButtonStyle(kind: .circular))
            .help("搜索（⌘K）")
            .accessibilityLabel("搜索")
            .disabled(!workspace.isLibraryReady)
            .opacity(shown ? 1 : 0).allowsHitTesting(shown).accessibilityHidden(!shown)
            .padding(.leading, Spacing.toolbarGap)
    }
}

extension Workspace {
    /// 进展页的看板（没开编辑页时）：窗口最顶那一排写着四个列头（`boardTopRow`），搜索收进"⋯"。
    var boardOwnsTopRow: Bool { root == .progress && progressPane == .board && openCard == nil }

    /// 进展页的会话段：那一排左边是项目范围，右边额度环与新会话。
    var showsSessionsBar: Bool { root == .progress && progressPane == .sessions }
}
#endif
