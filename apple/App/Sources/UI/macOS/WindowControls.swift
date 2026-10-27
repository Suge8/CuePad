#if os(macOS)
import CueStore
import SwiftUI

/// 窗口最顶那一排左边的一项（侧栏钮之后）：项目切换、"收起"、进展页的分段与范围排在同一个工具栏项里。
/// 宽 0 的工具栏项也占一格圆钮那么宽（36pt，实测），各成一项时会话页上看不见的几格就占掉一截，窄窗口里标题、搜索与"⋯"被挤进溢出菜单。
/// 开合侧栏时随侧栏滑的是工具栏的各项、变了宽的项原地出没（`SidebarSlide.riderMoved`）：进展页上这一项开合前后一样宽（项目切换不在那里），分段照常随侧栏滑。
struct LeadingSlots: View {
    var body: some View {
        HStack(spacing: 0) {
            SwitcherSlot()
            CloseButton()
            PanesSlot()
            ScopeSlot()
        }
        // 离侧栏的边、侧栏钮各空一点：工具栏把这一项贴着它们排；再多空，侧栏收起时英文的待办列头写不下列名
        .padding(.leading, Self.leadingGap)
    }

    private static let leadingGap: CGFloat = 4
}

/// 窗口最顶那一排右边的一项：同步提醒、会话段的新会话、搜索、"⋯"排在同一个工具栏项里（理由同 `LeadingSlots`）。
struct TrailingSlots: View {
    var body: some View {
        // 间隔由各控件自己在前面留（`toolbarGap`）：宽 0 的那几格不多出空隙
        HStack(spacing: 0) {
            SyncAlertSlot()
            PageActionSlot()
            LibraryHelpSlot()
            CueListSlots()
            SearchSlot()
            PageMenuSlot()
        }
    }
}

extension View {
    /// 工具栏里在这一页上暂时用不上的控件（进展页两段之间换着用的几样）：看不见、不接点，宽度照旧，换段时工具栏不重排。
    func toolbarVisible(_ shown: Bool) -> some View {
        opacity(shown ? 1 : 0).allowsHitTesting(shown).accessibilityHidden(!shown)
    }

    /// 只在一部分时候有的工具栏控件（侧栏收起时的项目切换、进展页的几格）：不在时宽 0、看不见，仍挂着（再出现时不现建，项目菜单不重算）。
    /// 宽度不跟动画走：工具栏项每帧变一次宽，整条工具栏就每帧重新约束一遍。
    func toolbarPresence(_ present: Bool) -> some View {
        frame(width: present ? nil : 0, alignment: .leading)
            .clipped()
            .toolbarVisible(present)
            .animation(nil, value: present)
    }
}

/// 侧栏收起时的项目切换（紧跟在侧栏钮后面）。进展页、技能与规则页上没有它：左上的分段已经说了在哪一页；进展页上它再占一截就把分段推到待办那一列上面、
/// 待办的列头只剩个数（去别处用侧栏钮、⌘1–9）。单独一个视图读侧栏开合：主窗口的视图体读了它，开合的那一帧就要重算整个窗口、重新提交整条工具栏。
struct SwitcherSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let shown = workspace.pages.sidebar == .detailOnly && workspace.root != .progress && workspace.root != .library
        // 不用 disabled：环境一变整份菜单又要重算；⌘1–9 本来就由窗口快捷键（`WorkspaceShortcuts`）接，菜单里的只是提示
        // 玻璃与墨色字自己画，同右边的项目范围（`ProjectScopeMenu`）：交给工具栏画时，没焦点的窗口里字是停用的淡灰
        ProjectSwitcher(collapsed: shown)
            .menuStyle(.button).buttonStyle(ControlButtonStyle(kind: .glass))
            .padding(.trailing, Spacing.toolbarGap)
            .toolbarPresence(shown)
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

/// 工具栏左上的"收起"：只在开着编辑页时有（灵感的编辑页、技能与规则的文件页，Esc 同），没有时不占位置。
/// 一颗返回图标的圆钮（同手机推入页左上的系统返回），悬停提示与读屏说"收起"。
struct CloseButton: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if workspace.overlay != nil {
            // 箭头比放大镜、"⋯"细瘦：大一号、粗一档，与它们一样重
            Button { workspace.overlay = nil } label: { Image(.back).font(Glyph.control.weight(.bold)) }
            .buttonStyle(ControlButtonStyle(kind: .circular))
            .keyboardShortcut(.cancelAction)
            .help("收起（Esc）")
            .accessibilityLabel("收起")
            .padding(.trailing, Spacing.toolbarGap)
        }
    }
}

/// 工具栏左边、侧栏钮（与侧栏收起时的项目切换）之后：进展页两段的图标分段（`ProgressPanes`，同 iPhone 顶上那块玻璃里那一组），两段同一个位置。
/// 分段本该在中间（`PageTitleSlot`）：看板段那一排是四个列头、各对齐自己那一列，中间正是推进中、等你的列头，放中间就压住它们，所以留在左上、待办那一列上方。
/// 右沿报给看板段的列头（`MacPages.panesEdge`）：它下面的列头从它右边起，不压在分段下面。
struct PanesSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        PageControl(.progress) { ProgressPanes().frame(height: PaneMetrics.square).padding(PaneMetrics.inset).glass(in: .capsule) }
            .background { WindowFrame(\.maxX) { workspace.pages.panesEdge = $0 } }
            .toolbarPresence(workspace.root == .progress)
    }
}

/// 量这一块在窗口里的框（左上为原点，同窗口里浮层的坐标），或它的一条边（`CGRect.minX`、`maxX`）：工具栏项与页面不在同一棵视图里，
/// SwiftUI 的全局坐标对不上，按窗口坐标量。开合侧栏、拖侧栏的宽时挪的是外面的几层（工具栏项那一格），听这几层的框变了再量。
struct WindowFrame<Value: Equatable>: NSViewRepresentable {
    let edge: KeyPath<CGRect, Value>
    let report: (Value) -> Void

    init(_ edge: KeyPath<CGRect, Value>, report: @escaping (Value) -> Void) {
        self.edge = edge
        self.report = report
    }

    func makeNSView(context: Context) -> Probe { Probe(edge: edge, report: report) }
    func updateNSView(_ probe: Probe, context: Context) { probe.report = report }

    final class Probe: NSView {
        let edge: KeyPath<CGRect, Value>
        var report: (Value) -> Void
        private var observers: [any NSObjectProtocol] = []
        private var last: Value?

        init(edge: KeyPath<CGRect, Value>, report: @escaping (Value) -> Void) {
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
            guard let window else { return }
            let frame = convert(bounds, to: nil)
            let height = window.contentView?.bounds.height ?? 0
            let x = CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)[keyPath: edge]
            guard x != last else { return }
            last = x
            // 不在布局的这一圈里改可观察的值
            DispatchQueue.main.async { [report] in report(x) }
        }
    }
}

/// 工具栏左边、两段分段之后：这一页的范围，进展页的会话段是项目范围（`ProjectScopeMenu`，`Workspace.projectScope`；看板段那一排是列头，范围在"⋯"里）。
/// 工具栏里的页面控件只有一条规矩（这一格、`PanesSlot`、`PageActionSlot`、`SearchSlot`、`PageMenuSlot` 都照它）：只放 Workspace 里已有的状态，
/// 工具栏读不到页面读的库，抄一份过来就是第二个事实源。控件都一直挂着（换页时不现建整份项目菜单）、只换内容：工具栏项一增删整条重建（实测占进出会话页点击回合的一半，25fdb5fa、4fd371a4）。
/// 只属于进展页的几格（这一格、分段、新会话）在别的页宽 0（`toolbarPresence`），随进展页第一次挂上才建（`PageControl`），进出进展页时整条重排一次（一次 100～150ms 的重排是逐帧变宽时量的，b9707fc5）；
/// 进展页两段之间宽度不变，换段只换哪几样看得见（`toolbarVisible`）。这一格按项目名的宽、最宽 `maxWidth`（再长截断），只在换范围时变宽变窄；
/// 状态归页面的（会话段的搜索、新会话表单读的这台 Mac 上有哪些 Agent）留在页里。
struct ScopeSlot: View {
    @Environment(Workspace.self) private var workspace

    private static let maxWidth: CGFloat = 200

    var body: some View {
        PageControl(.progress) { ProjectScopeMenu() }
            .frame(maxWidth: Self.maxWidth, minHeight: Spacing.toolbarControl, maxHeight: Spacing.toolbarControl)
            .toolbarVisible(workspace.showsSessionsBar)
            .padding(.leading, Spacing.toolbarGap)
            .toolbarPresence(workspace.root == .progress)
    }
}

/// 只属于一页的工具栏控件（进展页的 `PanesSlot`、`ScopeSlot`、`PageActionSlot`，技能与规则页的 `LibraryHelpSlot`）：
/// 别的页上宽 0、看不见。随那一页一起挂上——进展页在启动后空闲时先挂上（`Prewarm`），或一打开就在那一页——之后一直挂着；
/// 挂上之前不建，冷启动的第一帧不建看不见的分段、项目菜单、玻璃与新会话钮。
struct PageControl<Content: View>: View {
    let page: Route
    let content: Content
    @Environment(Workspace.self) private var workspace
    @State private var mounted = false

    init(_ page: Route, @ViewBuilder content: () -> Content) {
        self.page = page
        self.content = content()
    }

    var body: some View {
        let due = workspace.mountedPages.contains(page)
        ZStack { if mounted || due { content } }
            .onChange(of: due, initial: true) { if $1 { mounted = true } }
    }
}

/// 工具栏右边、搜索之前：Cue 页的记忆与定时两颗圆钮，各打开自己的弹层（`CueMemoryPage`、`CueSchedulePage`）。规矩同 `ScopeSlot`。
struct CueListSlots: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let cue = workspace.cue
        PageControl(.cue) {
            HStack(spacing: Spacing.toolbarGap) {
                Button("\(cue.name) 记得什么", icon: .memory) { cue.showsMemory = true }
                    .help("\(cue.name) 记得什么")
                Button("定时", icon: .schedule) { cue.showsSchedules = true }
                    .help("定时")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(ControlButtonStyle(kind: .circular))
        }
        .padding(.leading, Spacing.toolbarGap)
        .toolbarPresence(workspace.root == .cue)
    }
}

/// 工具栏右边、搜索之前：进展页会话段的"新会话"（弹出新会话的表单，`NewSessionPanel`，⌥⌘N 同）；看板段的新任务在"⋯"里。
/// 规矩同 `ScopeSlot`；宽度就是字宽（字不随页变）。
struct PageActionSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        // 工具栏把"图标 + 字"的标签只画成图标：写明两样都要
        PageControl(.progress) {
            Button("新会话", icon: .add) { workspace.showsNewSession = true }
                .labelStyle(.titleAndIcon)
                .buttonStyle(ControlButtonStyle(kind: .glass))
                .help("开一个新的 Agent 会话（⌥⌘N）")
        }
        .toolbarVisible(workspace.showsSessionsBar)
        .fixedSize()
        .frame(height: Spacing.toolbarControl)
        .padding(.leading, Spacing.toolbarGap)
        .toolbarPresence(workspace.root == .progress)
    }
}

/// 工具栏右边最前面：同步需要关注时（没登录 iCloud、连不上、需要你决定、出错等）露一个图标，悬停看原因，点开设置处理。
/// 有同步就常驻一格圆钮宽，平时只是看不见：提醒一出一收不挤动标题与搜索（工具栏项一变宽整条重排，窄窗口里居中的标题跟着挪）。
struct SyncAlertSlot: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        let summary = SyncSummary(services.syncStatus)
        Button { SettingsPane.open(.general) } label: {
            Image(summary.icon).foregroundStyle(palette.color(summary.tone))
        }
        .buttonStyle(ControlButtonStyle(kind: .circular))
        .help([summary.title, summary.detail, String(localized: "点按在设置里处理")].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityLabel(summary.title)
        .toolbarVisible(summary.tone != .calm)
        .toolbarPresence(services.sync != nil)
    }
}

/// 工具栏右边的搜索（⌘K 同）。进展页上不在这里，收在"⋯"里（`PageMenuSlot`）：看板段那一排是列头，会话段那一排已有范围与新会话，页里还有搜会话的框。
struct SearchSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        // 资料库读不出来时：搜索结果能打开卡片，是写入入口
        Button { workspace.searching.toggle() } label: { Image(.search) }
            .buttonStyle(ControlButtonStyle(kind: .circular))
            .help("搜索（⌘K）")
            .accessibilityLabel("搜索")
            .disabled(!workspace.isLibraryReady)
            .padding(.leading, Spacing.toolbarGap)
            .toolbarPresence(workspace.root != .progress)
    }
}

extension Workspace {
    /// 进展页的会话段：那一排左边是项目范围，右边新会话。
    var showsSessionsBar: Bool { root == .progress && progressPane == .sessions }
}
#endif
