import CueStore
import SwiftUI
import WebKit

struct LivePreviewTool: View {
    let session: SessionRoute
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let button = workspace.liveButton(session.id)
        HeadTool(label: Self.label(button ?? .closed(nil)), icon: .livePreview, on: button?.isShowing == true) { workspace.toggleLivePreview(of: session) }
            .opacity(button == nil ? 0 : 1)
            .allowsHitTesting(button != nil)
            .readerHidden(button == nil)
            .animation(Motion.fade, value: button != nil)
    }

    static func label(_ button: Workspace.LiveButton) -> LocalizedStringResource {
        switch button {
        case .closed(let url?): "打开活预览：\(LiveAddress.shown(url))"
        case .closed(nil): "打开活预览"
        case .open(let url?): "收起活预览：\(LiveAddress.shown(url))"
        case .open(nil): "收起活预览"
        }
    }
}

struct LivePreviewPane: View {
    let preview: LivePreview
    @Environment(\.palette) private var palette
    @Environment(\.headInset) private var inset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(Workspace.self) private var workspace
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                if preview.address == nil {
                    #if os(macOS)
                    LiveAddressEntry(preview: preview).frame(maxWidth: .infinity, maxHeight: .infinity)
                    #endif
                } else {
                    screen(in: geometry.size)
                    if let trouble, preview.phase != .stopped {
                        EmptyState(mascot: .search, title: trouble.title, message: trouble.message, bare: true) { LiveTroubleAction(trouble: trouble, preview: preview) }
                            .padding(.horizontal, Spacing.page)
                            .frame(maxHeight: .infinity)
                            .transition(.opacity)
                    }
                    LiveBar(preview: preview).padding(inset).frame(height: Chrome.band)
                }
            }
            .animation(Motion.fade, value: preview.phase)
            .animation(Motion.fade, value: trouble)
            #if os(macOS)
            .onChange(of: Self.remoteZoom(width: geometry.size.width, remote: workspace.liveFill?.remote == true && preview.viewport != .phone), initial: true) { preview.web.pageZoom = $1 }
            #endif
        }
        .background(palette.desk, ignoresSafeAreaEdges: workspace.layout == .wide ? .all : [])
        .modifier(LivePageAsks(preview: preview))
        .task(id: preview.address) { await preview.watch() }
        #if os(iOS)
        .task(id: scenePhase == .background) { if scenePhase != .background { await workspace.connectLive(preview) } }
        #endif
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            guard workspace.panes.contains(where: { $0.previewed != nil }) else { return }
            LivePreview.paneSize = size
        }
        .onDisappear {
            if preview.picking { preview.cancelPick() }
            #if os(macOS)
            preview.agent.used = .now
            #endif
        }
    }

    private var trouble: LiveTrouble? {
        #if os(iOS)
        if let link = preview.link, let trouble = link.trouble ?? link.taken(preview.address) { return trouble }
        #endif
        return preview.phase == .waiting ? .starting : nil
    }

    private func screen(in size: CGSize) -> some View {
        let framed = workspace.layout == .wide
        let phone = framed && preview.viewport == .phone
        let page = Self.page(in: size, phone: phone, framed: framed)
        let room = Self.room(in: size)
        let height = framed ? page.height : size.height
        let width = page.width
        let top = phone ? Chrome.band + Spacing.item + max(0, room - height) / 2 : framed ? Self.screenTop : 0
        let shape = RoundedRectangle(cornerRadius: phone ? Radius.screen : framed ? CuePanel.radius : 0, style: .continuous)
        let ground = preview.ground ?? palette.paper
        let shown = preview.phase == .live && preview.revealed || preview.phase == .stopped
        return LiveWebView(preview: preview)
            .overlay(alignment: .top) {
                LinearGradient(colors: [ground, ground.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.fade)
                    .opacity(framed ? 0 : 1)
                    .allowsHitTesting(false)
            }
            .padding(.top, framed ? 0 : Chrome.band)
            .overlay {
                if preview.phase == .stopped {
                    LiveStopped(text: trouble?.title ?? "服务停了，等它回来", message: trouble?.message) { LiveTroubleAction(trouble: trouble, preview: preview) }
                }
            }
            .frame(width: width, height: height)
            .background(ground)
            .clipShape(shape)
            .overlay { shape.strokeBorder(palette.hair).opacity(framed ? 1 : 0) }
            .background { shape.fill(ground).elevation(framed ? .lifted : nil) }
            .opacity(shown ? 1 : 0)
            .position(x: size.width / 2, y: top + height / 2)
            .animation(Motion.spatial(Motion.travel, reduceMotion: reduceMotion), value: phone)
    }

    private static let fade: CGFloat = 20

    static func page(in size: CGSize, phone: Bool, framed: Bool = true) -> CGSize {
        if phone { return CGSize(width: min(LivePreview.phoneWidth, size.width - 2 * Spacing.page), height: min(room(in: size), LivePreview.phoneHeight)) }
        guard framed else { return CGSize(width: size.width, height: size.height - Chrome.band) }
        return CGSize(width: size.width - 2 * CuePanel.float, height: size.height - screenTop - CuePanel.float)
    }

    private static var screenTop: CGFloat { (Chrome.band + Chrome.control) / 2 + Spacing.item }

    /// 手机用 UU 远程看着时页面放大几倍：远程画面是整块屏幕缩到手机上，3008 宽的屏上照原样排的字在手机上只有两三个点高。
    /// 放大到页面按 `remoteWidth` 宽排版（仍是桌面那一套排法）：手机横过来看，正文约 11 点。屏本来就不比它宽的不放大；
    /// 手机宽那一档也不放大（那块屏还是 390 宽，放大了页面就按一百多宽排）。
    static func remoteZoom(width: CGFloat, remote: Bool) -> CGFloat {
        remote ? max(1, (width - 2 * CuePanel.float) / remoteWidth) : 1
    }

    private static let remoteWidth: CGFloat = 1024

    private static func room(in size: CGSize) -> CGFloat { size.height - Chrome.band - Spacing.item - Spacing.block }
}

private struct LivePageAsks: ViewModifier {
    let preview: LivePreview

    func body(content: Content) -> some View {
        let ask = preview.asks.first
        let shown = Binding { ask != nil } set: { if !$0, let ask { Task { preview.answer(ask.id, nil) } } }
        let text = Binding { preview.asks.first?.text ?? "" } set: { if !preview.asks.isEmpty { preview.asks[0].text = $0 } }
        let ok = DialogButton(title: "确定", role: ask?.kind == .alert ? .cancel : nil) { if let ask { preview.answer(ask.id, ask.kind == .prompt ? text.wrappedValue : "") } }
        content.dialog("\(ask?.origin ?? "") 上的网页说", isPresented: shown, message: ask.map { .verbatim($0.message) },
                       field: ask?.kind == .prompt ? DialogField(prompt: "填写回答", text: text) : nil, buttons: [ok])
    }
}

#if os(macOS)
private struct LiveWebView: NSViewRepresentable {
    let preview: LivePreview

    func makeCoordinator() -> LivePreview { preview }

    func makeNSView(context: Context) -> WKWebView {
        preview.enteredPane()
        return preview.web
    }

    func updateNSView(_ web: WKWebView, context: Context) {}

    static func dismantleNSView(_ web: WKWebView, coordinator: LivePreview) { coordinator.leftPane() }
}
#else
private struct LiveWebView: UIViewRepresentable {
    let preview: LivePreview

    func makeUIView(context: Context) -> WKWebView { preview.web }

    func updateUIView(_ web: WKWebView, context: Context) {}
}
#endif

extension Workspace {
    struct LiveFill: Equatable {
        let session: UUID
        var own = true
        var remote = false
    }

    func toggleLiveFill() {
        guard liveFill == nil else { return endLiveFill() }
        guard let session = liveSession, showsLivePreview(session.id) else { return }
        liveFill = LiveFill(session: session.id)
    }

    func endLiveFill() {
        guard let fill = liveFill else { return }
        liveFill = nil
        #if os(macOS)
        livePreviews[fill.session]?.web.pageZoom = 1
        services.windowShell?.restoreFrame()
        #endif
    }

    enum LiveButton: Equatable {
        case closed(URL?)
        case open(URL?)

        var isShowing: Bool { if case .open = self { true } else { false } }
    }
}

nonisolated enum LiveTrouble: Equatable, Sendable {
    case starting, asking, offline, noWiFi, apart, isolated, denied, gone, taken

    var title: LocalizedStringResource {
        switch self {
        case .starting: "等开发服务起来"
        case .asking: "正在连 Mac"
        case .offline: "Mac 不在线"
        case .noWiFi: "没连 Wi-Fi"
        case .apart: "和 Mac 不在同一个网络"
        case .isolated: "连不上 Mac，这个 Wi-Fi 可能不让设备互相连接"
        case .denied: "没有本地网络权限，看不到 Mac 上的网页"
        case .gone: "服务停了，等它回来"
        case .taken: "这个端口在这台设备上被占着"
        }
    }

    var reachesByRemote: Bool { [.noWiFi, .apart, .isolated, .denied].contains(self) }

    var message: LocalizedStringResource? { reachesByRemote && self != .denied ? "用 UU 远程看 Mac 上的这一页" : nil }
}

private struct LiveTroubleAction: View {
    let trouble: LiveTrouble?
    let preview: LivePreview
    #if os(iOS)
    @Environment(Workspace.self) private var workspace
    @State private var opening = false
    #endif

    var body: some View {
        #if os(iOS)
        if trouble?.reachesByRemote == true {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.item) { buttons }
                VStack(spacing: Spacing.item) { buttons }
            }
        }
        #endif
    }

    #if os(iOS)
    @ViewBuilder private var buttons: some View {
        if trouble == .denied, let settings = URL(string: UIApplication.openSettingsURLString) {
            Button("去设置") { UIApplication.shared.open(settings) }.buttonStyle(ControlButtonStyle(kind: .primary))
        }
        Button("在 Mac 上操作", icon: .remoteMac) {
            guard !opening else { return }
            opening = true
            Task {
                await workspace.viewOnMac(preview)
                opening = false
            }
        }
        .buttonStyle(ControlButtonStyle(kind: trouble == .denied ? .secondary : .primary))
        .accessibilityHint("用网易 UU 远程控制 Mac")
    }
    #endif
}

private struct LiveStopped<Action: View>: View {
    let text: LocalizedStringResource
    var message: LocalizedStringResource?
    @ViewBuilder var action: Action
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            palette.stale
            VStack(spacing: Spacing.block) {
                if let message {
                    VStack(spacing: Spacing.tight) {
                        status
                        Text(message).font(Typography.caption).foregroundStyle(palette.ink2)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.block)
                    .padding(.vertical, Spacing.item)
                    .glass(in: .rect(cornerRadius: Radius.sheet))
                } else {
                    status
                        .padding(.horizontal, Spacing.block)
                        .frame(height: Chrome.control)
                        .glass(in: .capsule)
                }
                action
            }
            .padding(.horizontal, Spacing.page)
        }
        .allowsHitTesting(true)
        .transition(.opacity)
    }

    private var status: some View {
        HStack(spacing: Spacing.glyph) {
            Spinner(.small)
            Text(text)
        }
        .font(Typography.secondary.weight(.medium))
        .foregroundStyle(palette.ink)
    }
}

#if os(macOS)
private struct LiveAddressEntry: View {
    let preview: LivePreview
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.palette) private var palette

    private static let width: CGFloat = 400

    var body: some View {
        TextField(text: $text, prompt: Text("输入地址").foregroundStyle(palette.ink3)) { Text("地址") }
            .textFieldStyle(.plain)
            .font(Typography.searchField)
            .foregroundStyle(palette.ink)
            .multilineTextAlignment(.center)
            .focused($focused)
            .onSubmit { if let url = LiveAddress.url(from: text) { preview.retarget(.init(url: url, source: .typed)) } }
            .padding(.horizontal, Spacing.panel)
            .frame(height: ComposerMetrics.slot)
            .paper(cornerRadius: Radius.field)
            .frame(maxWidth: Self.width)
            .padding(.horizontal, Spacing.page)
            .defaultFocus($focused, true)
            .onAppear { focused = true }
    }
}
#endif
