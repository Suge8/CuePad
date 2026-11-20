import CueStore
import SwiftUI
import WebKit

/// 主区会话栏头开合活预览的那颗钮（`HeadTool`）：这个会话有页面可看或预览开着时才在（`Workspace.liveButton`），在本身就是"有服务"；
/// 没开同栏头别的钮，开着是强调色。来去只是它自己淡入淡出，栏头别的不挪。Mac 与 iPad 宽屏同一颗（手机的在页头，`LivePhoneTool`）。
struct LivePreviewTool: View {
    let session: SessionRoute
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let button = workspace.liveButton(session.id)
        // 没有时也占着位置、只是看不见：插进去再拿出来会挤得标题忽而截断、忽而放开
        HeadTool(label: Self.label(button ?? .closed(nil)), icon: .livePreview, on: button?.isShowing == true) { workspace.toggleLivePreview() }
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

/// 并排右半的活预览（`BesideColumn`）：网页铺满这一块，上缘滑到浮着的玻璃栏下面、下缘到窗口边；
/// 手机宽那一档收成 390 宽居中的一块屏，落在桌面上。两档之间是同一块连续地变宽变窄，网页不重新载入。
/// 手机上是铺满屏的一页（`LivePhoneCover`），栏换成手机那一排（`LiveBar`）。手机、iPad 上开着时连着 Mac（`LiveLink`），连不上的原因盖在页上。
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
                    // 只 Mac 有空着的地址（会话的菜单里手动打开）：手机、iPad 开时就有 Mac 答来的地址
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
        }
        .background(palette.desk)
        .modifier(LivePageAsks(preview: preview))
        .task(id: preview.address) { await preview.watch() }
        #if os(iOS)
        // 进后台也断开：回来是重新连上、整页重载（`LivePreview.linked`），不靠页面里断掉的热更新连接自己回来
        .task(id: scenePhase == .background) { if scenePhase != .background { await workspace.connectLive(preview) } }
        #endif
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            // 收起时滑出去的那一程按不并排的宽排着：不记它，后台预览（`LiveHost`）按开着时的大小排版
            guard case .preview = workspace.beside else { return }
            LivePreview.paneSize = size
        }
        .onDisappear {
            if preview.picking { preview.cancelPick() }
            #if os(macOS)
            // 收起才开始算闲置（`Workspace.releaseLivePreviews`）
            preview.agent.used = .now
            #endif
        }
    }

    /// 页面出不来的原因：服务还没起来；手机、iPad 上还有连不上 Mac 的那几种（`LiveLink.State`）。
    private var trouble: LiveTrouble? {
        #if os(iOS)
        if let trouble = preview.link?.trouble { return trouble }
        #endif
        return preview.phase == .waiting ? .starting : nil
    }

    /// 铺满时网页从玻璃栏下沿铺到窗口下缘，栏那一排铺页面的底、下沿同色渐隐：滚上去的内容淡进栏下，不在一条线上切断；
    /// 手机宽时是栏下面居中的一块屏。两档之间网页只换位置与宽，不换内边距：内容不跳。
    private func screen(in size: CGSize) -> some View {
        let phone = preview.viewport == .phone
        let page = Self.page(in: size, phone: phone)
        let room = Self.room(in: size)
        let height = phone ? page.height : size.height
        let width = page.width
        let top = phone ? Chrome.band + Spacing.item + max(0, room - height) / 2 : 0
        let shape = RoundedRectangle(cornerRadius: phone ? Radius.screen : 0, style: .continuous)
        let ground = preview.ground ?? palette.paper
        let shown = preview.phase == .live && preview.revealed || preview.phase == .stopped
        return LiveWebView(preview: preview)
            .overlay(alignment: .top) {
                LinearGradient(colors: [ground, ground.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.fade)
                    .opacity(phone ? 0 : 1)
                    .allowsHitTesting(false)
            }
            .padding(.top, phone ? 0 : Chrome.band)
            .overlay {
                if preview.phase == .stopped {
                    LiveStopped(text: trouble?.title ?? "服务停了，等它回来", message: trouble?.message) { LiveTroubleAction(trouble: trouble, preview: preview) }
                }
            }
            .frame(width: width, height: height)
            .background(ground)
            .clipShape(shape)
            .overlay { shape.strokeBorder(palette.hair).opacity(phone ? 1 : 0) }
            .background { shape.fill(ground).elevation(phone ? .lifted : nil) }
            .opacity(shown ? 1 : 0)
            .position(x: size.width / 2, y: top + height / 2)
            .animation(Motion.spatial(Motion.travel, reduceMotion: reduceMotion), value: phone)
    }

    private static let fade: CGFloat = 20

    /// 网页视图在这么大的面板里的大小：后台预览（`LiveHost`）也照它排版，用户点开时页面不换一套排版。
    static func page(in size: CGSize, phone: Bool) -> CGSize {
        guard phone else { return CGSize(width: size.width, height: size.height - Chrome.band) }
        return CGSize(width: min(LivePreview.phoneWidth, size.width - 2 * Spacing.page), height: min(room(in: size), LivePreview.phoneHeight))
    }

    /// 手机屏离玻璃栏下沿与离窗口下缘一样远
    private static func room(in size: CGSize) -> CGFloat { size.height - Chrome.band - Spacing.item - Spacing.block }
}

/// 网页弹的 alert、confirm、prompt（`LivePreview.asks`）：项目的确认卡（`dialog`），标题写哪个网站在说话。面板收着时等它开了再给你看，网页在那一句上等着。
/// 点外面、Esc 是取消；alert 只有一颗钮。卡关上与按钮动作是先后两下，取消挪到下一拍：按了钮的那一句先答上，取消落空。
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
    enum LiveButton: Equatable {
        /// 点开就是这个地址；nil 是空的地址输入。
        case closed(URL?)
        case open(URL?)

        var isShowing: Bool { if case .open = self { true } else { false } }
    }
}

/// 页面出不来的原因，盖在预览上的那一句。
nonisolated enum LiveTrouble: Equatable, Sendable {
    case starting, asking, offline, noWiFi, apart, isolated, denied, gone

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
        }
    }

    /// 连不上的是手机到 Mac 的这段路、Mac 本身在线：可以用 UU 远程到 Mac 上看（`Workspace.viewOnMac`）。
    var reachesByRemote: Bool { [.noWiFi, .apart, .isolated, .denied].contains(self) }

    /// 只有 UU 远程是主要出路的才说；没给权限的主要出路是去设置。
    var message: LocalizedStringResource? { reachesByRemote && self != .denied ? "用 UU 远程看 Mac 上的这一页" : nil }
}

/// 缺本地网络权限时去设置打开；手机到 Mac 的路不通时用 UU 远程到 Mac 上看（没给权限时排在去设置后面）；别的没有可做的，等它自己回来。
private struct LiveTroubleAction: View {
    let trouble: LiveTrouble?
    let preview: LivePreview
    #if os(iOS)
    @Environment(Workspace.self) private var workspace
    @State private var opening = false
    #endif

    var body: some View {
        #if os(iOS)
        // 没有钮时什么都不出：一排空的也会让所在的 VStack 多留一段间距，那一句跟着上移
        if trouble?.reachesByRemote == true {
            // 并排放不下（大字号）就上下排，不在钮里折行
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

/// 服务停了、连不上 Mac 了：最后的画面压暗一层留着，上面浮一句；回来时自动重新载入（`LivePreview.watch`），这一层随之撤掉。
/// 有可做的（`LiveTroubleAction`）排在那一句下面，点了会怎样（`message`）写在那一句里第二行，同空态。
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
/// 还没有地址：面板中间只有一个地址输入，焦点已在里面。
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
