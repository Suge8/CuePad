#if os(macOS)
import AppKit
import SwiftUI

extension View {
    func presentPanel<Item: Identifiable>(
        item: Binding<Item?>, style: PanelStyle, close: ClosePanel, @ViewBuilder content: @escaping (Item) -> some View
    ) -> some View {
        let shown = item.wrappedValue
        return modifier(WindowPanel(key: shown.map { AnyHashable($0.id) }, retained: false, style: style, close: close) { if let shown { content(shown) } })
    }

    /// 常驻的模态浮层（⌘K）：`mounted` 之后内容一直挂在窗口里，收起只是透明、点不到、暂停订阅（`pageActive`），再开不重建。
    /// 一次建文本框、筛选条与列表要几十毫秒，开合又是每天很多次的事；`mounted` 前（第一次开之前）与普通浮层一样开时才建。
    func keptPanel(isPresented: Binding<Bool>, mounted: Bool, @ViewBuilder content: @escaping () -> some View) -> some View {
        modifier(WindowPanel(
            key: isPresented.wrappedValue ? AnyHashable(true) : nil, retained: mounted, style: .sheet,
            close: ClosePanel { isPresented.wrappedValue = false }, panel: content))
    }
}

extension View {
    /// 每个窗口的根视图挂一次：本窗口的浮层都画在这里，盖住整窗（含侧栏）。点浮层外面任意处（含工具栏）或按 Esc 关最上面那一层（`PanelHost`）；
    /// 模态的开着时按键不进下面那层界面，读屏只在浮层里（`isModal`）。环境要在它外面注入，浮层内容才拿得到。
    func panelHost() -> some View { modifier(PanelHostModifier()) }
}

/// 本窗口此刻的浮层，后开的在上（右上角的面板总在模态浮层之下）。
@Observable
final class PanelHost {
    struct Shown: Identifiable {
        let id: UUID
        let style: PanelStyle
        let content: AnyView
        let close: ClosePanel
        /// 常驻的浮层收起时仍在 `shown` 里（`open` 为 false）。
        var open = true
        var modal: Bool { style.modal }
    }

    private(set) var shown: [Shown] = []
    /// 本窗口（`PanelHostModifier` 挂上时报来）。
    @ObservationIgnored fileprivate weak var window: NSWindow?
    /// 模态浮层弹出前的焦点，收起后交还（同系统 sheet）；弹出时先让窗口交出焦点，打字不会落进下面的编辑器。
    @ObservationIgnored private var responders: [UUID: Weak<NSResponder>] = [:]
    /// 各浮层占的地方与弹出它的视图（`takes`）。
    @ObservationIgnored fileprivate var bounds: [UUID: Bounds] = [:]
    /// 有浮层时本窗口的按键与点按先经这里（`takes`）。
    @ObservationIgnored private var monitor: Any?

    /// `open` 为 false：只把内容挂着（常驻浮层收起的样子）；已开着的变成收起。
    func show(_ id: UUID, style: PanelStyle, content: AnyView, close: ClosePanel, open: Bool = true) {
        var entry = Shown(id: id, style: style, content: content, close: close)
        entry.open = open
        if let index = shown.firstIndex(where: { $0.id == id }) {
            let wasOpen = shown[index].open
            shown[index] = entry
            if wasOpen && !open { closed(id) } else if !wasOpen && open { opened(entry) }
            return
        }
        if open { opened(entry) } else { shown.append(entry) }
    }

    private func opened(_ entry: Shown) {
        let id = entry.id
        if entry.modal {
            if let window {
                responders[id] = Weak(value: window.firstResponder)
                window.makeFirstResponder(nil)
            }
            if let index = shown.firstIndex(where: { $0.id == id }) { shown[index] = entry } else { shown.append(entry) }
        } else if case .bubble = entry.style {
            // 气泡在右上角的面板之上（从面板里的任务点开的也盖在它上面），外面那一下先关它。
            // 焦点交出去、收起时不交还（同点在别处）：开着时打字不落进下面的输入栏；交还的话换一条时输入栏要先展开再收起，大库里一次多约 2000M 指令
            window?.makeFirstResponder(nil)
            withAnimation(Motion.snappy) { shown.append(entry) }
        } else {
            withAnimation(Motion.snappy) { shown.insert(entry, at: 0) }
        }
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.takes(event) == true } ? nil : event
            }
        }
    }

    func hide(_ id: UUID) {
        guard let index = shown.firstIndex(where: { $0.id == id }) else { return }
        if shown[index].modal {
            shown.remove(at: index)
        } else {
            withAnimation(Motion.snappy) { _ = shown.remove(at: index) }
        }
        bounds[id] = nil
        released(id)
    }

    private func closed(_ id: UUID) {
        guard let index = shown.firstIndex(where: { $0.id == id }) else { return }
        shown[index].open = false
        released(id)
    }

    /// 浮层收起后：焦点交还，没有开着的浮层了就撤掉按键监听。
    private func released(_ id: UUID) {
        // 弹出前焦点在输入框里才交还；不在输入框时（点了按钮弹出的）让窗口自己当第一响应者，同弹出前——交还给 SwiftUI 的宿主视图
        // 会让它挑页面上第一个输入框接焦点（Agent 整页的搜索框），按空格就打进了搜索框
        if let responder = responders.removeValue(forKey: id)?.value, let window { window.makeFirstResponder(responder is NSText ? responder : nil) }
        if !shown.contains(where: \.open), let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// 这个事件由浮层接下（不再交给窗口）则为真。关法只有一套：Esc 或在最上面那一层外面按下鼠标（左右键、本窗口任意处，含工具栏），关它。
    /// 这一下交不交给下面同系统：模态的接下（sheet 外点不穿透）；右上角的面板同 SwiftUI 的 popover（实测），照常落到下面，
    /// 只有落在弹出它的视图（锚点，如侧栏的"任务"）上时接下——否则它松开时又把面板开回来。
    /// 模态的开着时：带 ⌘ 的组合键不交给窗口（下面那层的快捷键都在窗口里），先走主菜单——拷贝、粘贴、全选这些编辑命令由主菜单发给浮层里的
    /// 输入框；主菜单不接的再只问焦点所在的视图（浮层里编辑器的 ⌘↩），不问整个窗口。
    /// 不用停用（`disabled`）下面那层来做模态：停用整窗开、关各多 20～25ms。
    private func takes(_ event: NSEvent) -> Bool {
        guard let top = shown.last(where: \.open), let window, event.window === window else { return false }
        if event.type == .keyDown {
            if event.keyCode == Self.escape {
                top.close()
                return true
            }
            guard shown.contains(where: { $0.modal && $0.open }), event.modifierFlags.contains(.command) else { return false }
            if NSApp.mainMenu?.performKeyEquivalent(with: event) != true { _ = (window.firstResponder as? NSView)?.performKeyEquivalent(with: event) }
            return true
        }
        let bounds = bounds[top.id]
        if bounds?.panel.contains(event) == true { return false }
        top.close()
        return top.modal || bounds?.anchor.contains(event) == true
    }

    private static let escape: UInt16 = 53
}

private struct Weak<Object: AnyObject> {
    weak var value: Object?
}

extension Weak<NSView> {
    /// 这一下鼠标落在它占的地方。
    func contains(_ event: NSEvent) -> Bool {
        guard let value else { return false }
        return value.bounds.contains(value.convert(event.locationInWindow, from: nil))
    }
}

/// 一个浮层占的地方（`PanelLayer` 垫在内容下面）与弹出它的视图（`WindowPanel` 垫在调用处下面，开着时才有）。
private struct Bounds {
    var panel = Weak<NSView>()
    var anchor = Weak<NSView>()
}

/// 垫在一块界面下面、量它占的地方的空视图（不接点按）；建好时交给 `mark` 登记。
private struct AreaMark: NSViewRepresentable {
    let mark: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = Inert()
        mark(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class Inert: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct WindowPanel<Panel: View>: ViewModifier {
    /// 浮层的身份；nil 是收起。换了身份（另一项）就换内容。
    let key: AnyHashable?
    /// 收起后内容仍挂着（`keptPanel`）。
    let retained: Bool
    let style: PanelStyle
    let close: ClosePanel
    @ViewBuilder let panel: () -> Panel
    @Environment(PanelHost.self) private var host
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .background {
                if key != nil { AreaMark { [host, token] in host.bounds[token, default: Bounds()].anchor.value = $0 } }
            }
            .onChange(of: Mode(key: key, retained: retained), initial: true) { _, mode in
                if mode.key != nil || mode.retained {
                    host.show(token, style: style, content: AnyView(panel().environment(\.closePanel, close)), close: close, open: mode.key != nil)
                } else {
                    host.hide(token)
                }
            }
            .onDisappear { host.hide(token) }
    }
}

private struct Mode: Equatable {
    let key: AnyHashable?
    let retained: Bool
}

private struct PanelHostModifier: ViewModifier {
    @State private var host = PanelHost()

    func body(content: Content) -> some View {
        content
            .overlay { PanelLayer() }
            .background { WindowReader(host: host) }
            .environment(host)
    }
}

/// 把所在的窗口报给 `PanelHost`。
private struct WindowReader: NSViewRepresentable {
    let host: PanelHost

    func makeNSView(context: Context) -> Probe { Probe(host: host) }
    func updateNSView(_ view: Probe, context: Context) {}

    final class Probe: NSView {
        private let host: PanelHost

        init(host: PanelHost) {
            self.host = host
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            host.window = window
        }
    }
}

/// 浮层那一层。模态的：压暗整窗的底（挡住下面的悬停与滚动），居中一块圆角面板，内容自己定大小、太大时让出窗口四周 24。
/// 右上角的面板：页面轻轻压暗（不拦点按，背后透出来的卡片不和面板里的字抢），面板原地淡入淡出、不滑动——位置逐帧变时，AppKit 每帧
/// 重算整窗的鼠标跟踪区并重设光标（`NSTrackingAreaAKManager setCursorForMouseLocation`），前台每次开合 17～19 帧超时；淡入淡出不改几何，没有这笔。
private struct PanelLayer: View {
    @Environment(PanelHost.self) private var host
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let margin: CGFloat = 24

    var body: some View {
        ZStack {
            if host.shown.contains(where: { $0.style == .side }) {
                palette.backdrop.ignoresSafeArea().allowsHitTesting(false).transition(.opacity)
            }
            ForEach(host.shown) { shown in
                switch shown.style {
                case .sheet, .fullScreen: modal(shown)
                case .side: side(shown)
                case .bubble: EmptyView()
                }
            }
            bubbles
        }
    }

    private func modal(_ shown: PanelHost.Shown) -> some View {
        ZStack {
            if shown.open {
                palette.backdrop.ignoresSafeArea().accessibilityHidden(true)
            }
            shown.content
                .background { area(shown.id) }
                .clipShape(.rect(cornerRadius: PanelStyle.radius, style: .continuous))
                .rowContainer(.rect(cornerRadius: PanelStyle.radius, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: PanelStyle.radius, style: .continuous).strokeBorder(palette.hair) }
                .shadow(color: palette.panelShadow, radius: 28, y: 10)
                .accessibilityAddTraits(.isModal)
                .padding(Self.margin)
                // 常驻的浮层收起时：透明、点不到、读屏与按键快捷键都停用，订阅暂停
                .opacity(shown.open ? 1 : 0)
                .allowsHitTesting(shown.open)
                .disabled(!shown.open)
                .accessibilityHidden(!shown.open)
                .environment(\.pageActive, shown.open)
        }
    }

    private func side(_ shown: PanelHost.Shown) -> some View {
        shown.content
            .background { area(shown.id) }
            .padding(.trailing, 12).padding(.top, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .transition(.opacity)
    }

    /// 气泡：量窗口的那一层一直在，气泡在它里面进出（进出场要挂在被插入、移除的那一层上）；顶上让出工具栏那一条。
    private var bubbles: some View {
        GeometryReader { proxy in
            BubbleStage {
                ForEach(host.shown) { shown in
                    if case .bubble(let anchor) = shown.style {
                        let placement = BubblePlacement(anchor: anchor, container: proxy.size, insets: Self.bubbleInsets)
                        BubbleFrame(placement: placement) { shown.content } area: { area(shown.id) }
                            .transition(placement.transition(reduceMotion: reduceMotion))
                    }
                }
            }
        }
        .ignoresSafeArea()
    }

    private static let bubbleInsets = EdgeInsets(top: 52, leading: 12, bottom: 12, trailing: 12)

    private func area(_ id: UUID) -> some View {
        AreaMark { [host] in host.bounds[id, default: Bounds()].panel.value = $0 }
    }
}

/// Mac 浮层顶上一行：标题居中，右上一颗关闭（Esc 同）；`trailing` 在关闭钮左边（如"展开编辑"）。
struct PanelHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @Environment(\.palette) private var palette

    var body: some View {
        Text(title).font(Typography.toolbarTitle).foregroundStyle(palette.ink).lineLimit(1)
            .padding(.horizontal, 96)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
            .overlay(alignment: .trailing) {
                HStack(spacing: 10) {
                    trailing
                    PanelCloseButton()
                }
                .padding(.trailing, 16)
            }
    }
}

/// Mac 浮层右上的关闭钮（Esc 同）。
struct PanelCloseButton: View {
    @Environment(\.closePanel) private var close
    @Environment(\.palette) private var palette

    var body: some View {
        Button("关闭", icon: .close) { close() }
            .labelStyle(.iconOnly).font(Typography.meta.weight(.semibold)).foregroundStyle(palette.ink2)
            .frame(width: 26, height: 26).background(palette.fill, in: .circle).contentShape(.circle)
            .buttonStyle(PressStyle())
            .help("关闭（Esc）")
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

/// Mac 浮层里占满一行的搜索框，弹出即聚焦。
struct PanelSearchField: View {
    let prompt: String
    @Binding var text: String
    @FocusState private var focused: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Image(.search).foregroundStyle(palette.ink3).accessibilityHidden(true)
            TextField(prompt, text: $text, palette: palette).textFieldStyle(.plain).focused($focused)
        }
        .font(Typography.body)
        .padding(.horizontal, 12).frame(height: 34)
        .background(palette.fill, in: .rect(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 20)
        .onAppear { focused = true }
    }
}
#endif
