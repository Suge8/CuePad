#if os(macOS)
import CueStore
import SwiftUI

extension View {
    /// 暂时用不上、一会儿还要出现的栏头控件：看不见、不接点、读屏跳过，仍挂着、位置照留。只给一种：
    /// 一出一收会挤动同一排旁边的（同步提醒、技能与规则的说明）；其余按条件写。
    func keepsPlace(shown: Bool) -> some View {
        opacity(shown ? 1 : 0).allowsHitTesting(shown).accessibilityHidden(!shown)
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
            .padding(.trailing, Spacing.item)
        }
    }
}

/// 量这一块在窗口里的框（左上为原点，同窗口里浮层的坐标），或它的一条边（`CGRect.minX`、`maxX`）：宽屏几块各是一个托管视图，
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

/// 主区栏头右端、"⋯"之前：同步需要关注时（没登录 iCloud、连不上、需要你决定、出错等）露一个图标，悬停看原因，点开设置处理。
/// 有同步就常驻一格圆钮宽，平时只是看不见（`keepsPlace`）：提醒一出一收不挤动左边的编辑页标题与项目名。
struct SyncAlertSlot: View {
    /// 同步此刻要你关注（不在平静态）：看板那一排不常驻这一格，只在要关注时露出（`TaskBoardPage` 跟着让出）。
    static func needed(_ services: AppServices) -> Bool {
        services.sync != nil && SyncSummary(services.syncStatus).tone != .calm
    }

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

#endif
