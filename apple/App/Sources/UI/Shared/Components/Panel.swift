import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 关掉自己所在的弹层（`panel`）。Mac 的窗口内浮层没有系统的 `dismiss`，两端的弹层内容都用它。
struct ClosePanel {
    let run: @MainActor () -> Void
    @MainActor func callAsFunction() { run() }
}

extension EnvironmentValues {
    @Entry var closePanel = ClosePanel {}
}

extension View {
    /// 弹层（挂到任务、项目表单、选卡片、带上的卡片、预览、崩溃摘要）：调用处只给状态与内容，平台只换呈现。
    /// iOS 是系统 sheet（`fullScreen` 时全屏覆盖）；Mac 是窗口内浮层（`panelHost`）——AppKit 的窗口 sheet 开、关都把主线程
    /// 关在约 300ms 的嵌套动画循环里，关的那一段整窗不出帧。内容用环境里的 `closePanel` 关自己。
    func panel(isPresented: Binding<Bool>, fullScreen: Bool = false, @ViewBuilder content: @escaping () -> some View) -> some View {
        let close = ClosePanel { isPresented.wrappedValue = false }
        #if os(iOS)
        return Group {
            if fullScreen {
                self.fullScreenCover(isPresented: isPresented) { content().environment(\.closePanel, close) }
            } else {
                self.sheet(isPresented: isPresented) { content().environment(\.closePanel, close) }
            }
        }
        #else
        return modifier(WindowPanel(key: isPresented.wrappedValue ? AnyHashable(true) : nil, close: close) { content() })
        #endif
    }

    func panel<Item: Identifiable>(
        item: Binding<Item?>, fullScreen: Bool = false, @ViewBuilder content: @escaping (Item) -> some View
    ) -> some View {
        let close = ClosePanel { item.wrappedValue = nil }
        #if os(iOS)
        return Group {
            if fullScreen {
                self.fullScreenCover(item: item) { content($0).environment(\.closePanel, close) }
            } else {
                self.sheet(item: item) { content($0).environment(\.closePanel, close) }
            }
        }
        #else
        let shown = item.wrappedValue
        return modifier(WindowPanel(key: shown.map { AnyHashable($0.id) }, close: close) { if let shown { content(shown) } })
        #endif
    }
}

#if os(macOS)
extension View {
    /// 每个窗口的根视图挂一次：本窗口的弹层都画在这里，盖住整窗（含侧栏）。开着时是模态的：内容区的点按落在压暗的底上（点它关），
    /// 工具栏那一条的点按也是关掉弹层，按键不进下面那层界面（`PanelHost`），读屏只在弹层里（`isModal`）。
    /// 环境要在它外面注入，弹层内容才拿得到。
    func panelHost() -> some View { modifier(PanelHostModifier()) }
}

/// 本窗口此刻的弹层。只有一层：弹层里不再弹弹层（要选的东西就地在弹层里）。
@MainActor @Observable
final class PanelHost {
    struct Shown {
        let token: UUID
        let content: AnyView
        let close: ClosePanel
    }

    private(set) var shown: Shown?
    /// 本窗口（`PanelHostModifier` 挂上时报来）。
    @ObservationIgnored fileprivate weak var window: NSWindow?
    /// 弹出前的焦点：收起后交还（同系统 sheet）。弹出时先让窗口交出焦点，打字不会落进下面的编辑器。
    @ObservationIgnored private weak var responder: NSResponder?
    /// 弹层开着时本窗口的按键与工具栏点按先经这里（`takes`）。
    @ObservationIgnored private var monitor: Any?

    func show(_ token: UUID, content: AnyView, close: ClosePanel) {
        if shown == nil, let window {
            responder = window.firstResponder
            window.makeFirstResponder(nil)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.takes(event) == true } ? nil : event
            }
        }
        shown = Shown(token: token, content: content, close: close)
    }

    func hide(_ token: UUID) {
        guard shown?.token == token else { return }
        shown = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let window, let responder { window.makeFirstResponder(responder) }
        responder = nil
    }

    /// 模态而不停用下面那层界面：停用（`disabled`）要把整窗的控件重算一遍，开、关各多 20～25ms。
    /// Esc 关弹层；带 ⌘ 的组合键不交给窗口（下面那层的快捷键都在窗口里），只走主菜单——拷贝、粘贴、全选这些编辑命令
    /// 由主菜单发给弹层里的输入框；工具栏那一条（内容区之外、压暗的底盖不到）的点按等于点在弹层外面：关掉弹层。
    /// 这个事件由弹层接下（不再交给窗口）则为真。
    private func takes(_ event: NSEvent) -> Bool {
        guard let shown, let window, event.window === window else { return false }
        if event.type == .keyDown {
            if event.keyCode == Self.escape {
                shown.close()
                return true
            }
            guard event.modifierFlags.contains(.command) else { return false }
            _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
            return true
        }
        guard !window.contentLayoutRect.contains(event.locationInWindow) else { return false }
        shown.close()
        return true
    }

    private static let escape: UInt16 = 53
}

private struct WindowPanel<Panel: View>: ViewModifier {
    /// 弹层的身份；nil 是收起。换了身份（另一项）就换内容。
    let key: AnyHashable?
    let close: ClosePanel
    @ViewBuilder let panel: () -> Panel
    @Environment(PanelHost.self) private var host
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: key, initial: true) { _, key in
                if key != nil {
                    host.show(token, content: AnyView(panel().environment(\.closePanel, close)), close: close)
                } else {
                    host.hide(token)
                }
            }
            .onDisappear { host.hide(token) }
    }
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

/// 弹层的那一层：压暗的底（点它关），居中一块圆角面板。内容自己定大小，太大时让出窗口四周 24。
private struct PanelLayer: View {
    @Environment(PanelHost.self) private var host
    @Environment(\.palette) private var palette

    private static let radius: CGFloat = 16
    private static let margin: CGFloat = 24

    var body: some View {
        if let shown = host.shown {
            ZStack {
                palette.backdrop.ignoresSafeArea()
                    .onTapGesture { shown.close() }
                    .accessibilityHidden(true)
                shown.content
                    .clipShape(.rect(cornerRadius: Self.radius, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(palette.hair) }
                    .shadow(color: .black.opacity(palette.dark ? 0.45 : 0.18), radius: 28, y: 10)
                    .accessibilityAddTraits(.isModal)
                    .padding(Self.margin)
            }
        }
    }
}

/// Mac 弹层顶上一行：标题居中，右上一颗关闭（Esc 同）；`trailing` 在关闭钮左边（如"展开编辑"）。
struct PanelHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @Environment(\.closePanel) private var close
    @Environment(\.palette) private var palette

    var body: some View {
        Text(title).font(Typography.toolbarTitle).foregroundStyle(palette.ink).lineLimit(1)
            .padding(.horizontal, 96)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
            .overlay(alignment: .trailing) {
                HStack(spacing: 10) {
                    trailing
                    Button("关闭", systemImage: "xmark") { close() }
                        .labelStyle(.iconOnly).font(Typography.meta.weight(.semibold)).foregroundStyle(palette.ink2)
                        .frame(width: 26, height: 26).background(palette.fill, in: .circle).contentShape(.circle)
                        .buttonStyle(PressStyle())
                        .help("关闭（Esc）")
                }
                .padding(.trailing, 16)
            }
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

/// Mac 弹层里占满一行的搜索框，弹出即聚焦。
struct PanelSearchField: View {
    let prompt: String
    @Binding var text: String
    @FocusState private var focused: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(palette.ink3).accessibilityHidden(true)
            TextField(prompt, text: $text).textFieldStyle(.plain).focused($focused)
        }
        .font(Typography.body)
        .padding(.horizontal, 12).frame(height: 34)
        .background(palette.fill, in: .rect(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 20)
        .onAppear { focused = true }
    }
}
#endif
