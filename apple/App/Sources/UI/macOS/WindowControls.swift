#if os(macOS)
import CueStore
import SwiftUI

extension View {
    /// 暂时用不上、一会儿还要出现的栏头控件：看不见、不接点、读屏跳过，仍挂着、位置照留。只给两种：
    /// 一出一收会挤动同一排旁边的（同步提醒、技能与规则的说明），与来回换着用、现建要花一截首帧的（进展页会话段的范围与新会话）；其余按条件写。
    func keepsPlace(shown: Bool) -> some View {
        opacity(shown ? 1 : 0).allowsHitTesting(shown).accessibilityHidden(!shown)
    }
}

/// 开合会话条（`Workspace.toggleSidebar`，⌃⌘S 同，宽 220 与 72 两档）。收起时 Cue 有等你或新消息，钮角上带点（`CueDot`）。
struct SidebarToggle: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        // 点画在标签里：工具栏把"字 + 图标"的标签换成系统按钮，挂在按钮外面的会被丢掉
        Button { workspace.toggleSidebar() } label: {
            Image(.sidebar).overlay(alignment: .topTrailing) {
                if !workspace.sidebarOpen, workspace.mainRoute != .cue { CueDot().offset(x: 5, y: -4) }
            }
        }
        .accessibilityLabel("侧栏")
        .help("显示或隐藏侧栏（⌃⌘S）")
    }
}

/// 打开、收起卡片只改动下面三处（收起按钮、编辑页图层、底部输入条的位置），各自读"打开的卡"：
/// 主窗口的视图体不读它，开合时不重算整个窗口。

/// 主栏栏头里的"收起"：只在开着编辑页时有（灵感的编辑页、技能与规则的文件页，Esc 同），没有时不占位置。
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

/// 量这一块在窗口里的框（左上为原点，同窗口里浮层的坐标），或它的一条边（`CGRect.minX`、`maxX`）：两栏各是一个托管视图，
/// SwiftUI 的全局坐标只到所在那一栏，按窗口坐标量。会话条换宽时挪的是外面的几层，听这几层的框变了再量。
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

/// 进展页顶上那一排、两段分段之后：会话段的项目范围（`ProjectScopeMenu`，`Workspace.projectScope`；看板段那一排是列头，范围在"⋯"里）。
/// 栏头里的控件只有一条规矩（这一格、`PageActionSlot`、`SearchSlot`、`PageMenuSlot` 都照它）：只放 Workspace 里已有的状态，
/// 栏头读不到页面读的库，抄一份过来就是第二个事实源；状态归页面的（会话段的搜索、新会话表单读的这台 Mac 上有哪些 Agent）留在页里。
/// 只在会话段看得见，看板段仍挂着（`keepsPlace`）：换到会话段时现建整份项目菜单与新会话钮，那一下多 50～70M 条指令（13%～25%，后台量的"看板→会话"）。
/// 按项目名的宽、最宽 `maxWidth`（再长截断）。
struct ScopeSlot: View {
    @Environment(Workspace.self) private var workspace

    private static let maxWidth: CGFloat = 200

    var body: some View {
        ProjectScopeMenu()
            .frame(maxWidth: Self.maxWidth, minHeight: Spacing.toolbarControl, maxHeight: Spacing.toolbarControl)
            .padding(.leading, Spacing.toolbarGap)
            .keepsPlace(shown: workspace.showsSessionsBar)
    }
}

/// 右栏 Cue 页栏头的右边：记忆与定时两颗圆钮，各打开自己的弹层（`CueMemoryPage`、`CueSchedulePage`）。
struct CueListSlots: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let cue = workspace.cue
        HStack(spacing: Spacing.toolbarGap) {
            Button("\(cue.name) 记得什么", icon: .memory) { cue.showsMemory = true }
                .help("\(cue.name) 记得什么")
            Button("定时", icon: .schedule) { cue.showsSchedules = true }
                .help("定时")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(ControlButtonStyle(kind: .circular))
        .padding(.leading, Spacing.toolbarGap)
    }
}

/// 进展页顶上那一排的右边：会话段的"新会话"（弹出新会话的表单，`NewSessionPanel`，⌥⌘N 同）；看板段的新任务在"⋯"里。
/// 规矩同 `ScopeSlot`。
struct PageActionSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        // 写明图标与字两样都要
        Button("新会话", icon: .add) { workspace.showsNewSession = true }
            .labelStyle(.titleAndIcon)
            .buttonStyle(ControlButtonStyle(kind: .glass))
            .help("开一个新的 Agent 会话（⌥⌘N）")
            .fixedSize()
            .frame(height: Spacing.toolbarControl)
            .padding(.leading, Spacing.toolbarGap)
            .keepsPlace(shown: workspace.showsSessionsBar)
    }
}

/// 主栏栏头右边、搜索之前：同步需要关注时（没登录 iCloud、连不上、需要你决定、出错等）露一个图标，悬停看原因，点开设置处理。
/// 有同步就常驻一格圆钮宽，平时只是看不见（`keepsPlace`）：提醒一出一收不挤动左边的编辑页标题与项目名。
struct SyncAlertSlot: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        if services.sync != nil {
            let summary = SyncSummary(services.syncStatus)
            Button { SettingsPane.open(.general) } label: {
                Image(summary.icon).foregroundStyle(palette.color(summary.tone))
            }
            .buttonStyle(ControlButtonStyle(kind: .circular))
            .help([summary.title, summary.detail, String(localized: "点按在设置里处理")].compactMap { $0 }.joined(separator: "\n"))
            .accessibilityLabel(summary.title)
            .keepsPlace(shown: summary.tone != .calm)
        }
    }
}

/// 主栏栏头右边的搜索（⌘K 同）。进展页上不在这里，收在"⋯"里（`PageMenuSlot`）：看板段那一排是列头，会话段那一排已有范围与新会话，页里还有搜会话的框。
struct SearchSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        // 资料库读不出来时：搜索结果能打开卡片，是写入入口
        if workspace.mainRoute != .progress {
            Button { workspace.searching.toggle() } label: { Image(.search) }
                .buttonStyle(ControlButtonStyle(kind: .circular))
                .help("搜索（⌘K）")
                .accessibilityLabel("搜索")
                .disabled(!workspace.isLibraryReady)
                .padding(.leading, Spacing.toolbarGap)
        }
    }
}

extension Workspace {
    /// 进展页的会话段：那一排左边是项目范围，右边新会话。
    var showsSessionsBar: Bool { mainRoute == .progress && progressPane == .sessions }
}
#endif
