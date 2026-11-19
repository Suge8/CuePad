#if os(macOS)
import CueStore
import SwiftUI
import WebKit

/// 主区会话栏头开合活预览的那颗钮（`HeadTool`）：这个会话有页面可看或预览开着时才在（`Workspace.liveButton`），在本身就是"有服务"；
/// 没开同栏头别的钮，开着是强调色。来去只是它自己淡入淡出，栏头别的不挪。
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

    private static func label(_ button: Workspace.LiveButton) -> LocalizedStringResource {
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
struct LivePreviewPane: View {
    let preview: LivePreview
    @Environment(\.palette) private var palette
    @Environment(\.headInset) private var inset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                if preview.address == nil {
                    LiveAddressEntry(preview: preview).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    screen(in: geometry.size)
                    if preview.phase == .waiting {
                        EmptyState(mascot: .search, title: "等开发服务起来", bare: true) { EmptyView() }
                            .padding(.horizontal, Spacing.page)
                            .frame(maxHeight: .infinity)
                            .transition(.opacity)
                    }
                    LiveBar(preview: preview).padding(inset).frame(height: Chrome.band)
                }
            }
            .animation(Motion.fade, value: preview.phase)
        }
        .background(palette.desk)
        .task(id: preview.address) { await preview.watch() }
        .onDisappear { if preview.picking { preview.cancelPick() } }
    }

    /// 铺满时网页从玻璃栏下沿铺到窗口下缘，栏那一排铺页面的底、下沿同色渐隐：滚上去的内容淡进栏下，不在一条线上切断；
    /// 手机宽时是栏下面居中的一块屏。两档之间网页只换位置与宽，不换内边距：内容不跳。
    private func screen(in size: CGSize) -> some View {
        let phone = preview.viewport == .phone
        // 手机屏离玻璃栏下沿与离窗口下缘一样远
        let room = size.height - Chrome.band - Spacing.item - Spacing.block
        let height = phone ? min(room, LivePreview.phoneHeight) : size.height
        let width = phone ? min(LivePreview.phoneWidth, size.width - 2 * Spacing.page) : size.width
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
            .overlay { if preview.phase == .stopped { LiveStopped() } }
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
}

private struct LiveWebView: NSViewRepresentable {
    let preview: LivePreview

    func makeNSView(context: Context) -> WKWebView { preview.web }

    func updateNSView(_ web: WKWebView, context: Context) {}
}

/// 服务停了：最后的画面压暗一层留着，上面浮一句；服务回来时自动重新载入（`LivePreview.watch`），这一层随之撤掉。
private struct LiveStopped: View {
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            palette.stale
            HStack(spacing: Spacing.glyph) {
                Spinner(.small)
                Text("服务停了，等它回来")
            }
            .font(Typography.secondary.weight(.medium))
            .foregroundStyle(palette.ink)
            .padding(.horizontal, Spacing.block)
            .frame(height: Chrome.control)
            .glass(in: .capsule)
        }
        .allowsHitTesting(true)
        .transition(.opacity)
    }
}

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

/// 浮在网页上的玻璃栏：重新载入（载入中是停止）、地址、点选、手机宽、在浏览器里打开；载入进度是贴着下沿的一条细线。
/// 没有收起：收起只经左边会话栏头上打开它的那颗钮（`WideSessionTitle`），一件事一个入口。
private struct LiveBar: View {
    let preview: LivePreview
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let loading = preview.isLoading && preview.phase == .live
        HStack(spacing: Spacing.hair) {
            Group {
                if loading {
                    tool("停止载入", icon: .stop) { preview.stopLoading() }
                } else {
                    tool("重新载入", icon: .retry) { preview.reload() }
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            LiveAddressField(preview: preview)
            tool(preview.picking ? "退出点选" : "点选页面元素", icon: .pickElement, on: preview.picking) { workspace.pickElement() }
                .keyboardShortcut(preview.picking ? .cancelAction : nil)
                .disabled(preview.phase != .live)
            tool(preview.viewport == .phone ? "铺满" : "手机宽度", icon: .phoneWidth, on: preview.viewport == .phone) {
                withAnimation(Motion.spatial(Motion.travel, reduceMotion: reduceMotion)) { preview.viewport = preview.viewport == .phone ? .fill : .phone }
            }
            tool("在浏览器里打开", icon: .openInBrowser) { if let url = preview.shownAddress { NSWorkspace.shared.open(url) } }
                .disabled(preview.shownAddress == nil)
        }
        .padding(.horizontal, Spacing.tight)
        .frame(height: Chrome.control)
        .overlay { LiveProgress(value: preview.progress, shown: loading) }
        .glass(in: .capsule)
    }

    private func tool(_ label: LocalizedStringResource, icon: Icon, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(icon).foregroundStyle(on ? palette.signature : palette.ink) }
            .buttonStyle(ControlButtonStyle(kind: .icon, size: .compact))
            .help(Text(label))
            .accessibilityLabel(Text(label))
    }
}

/// 地址：平时居中写 `localhost:5173/路径`；点一下就地改，回车载入，Esc 或点开别处放弃。
/// 改的时候认出的其余服务挨着输入框列在下面（气泡），一行一个地址，点一个就换过去。
private struct LiveAddressField: View {
    let preview: LivePreview
    @State private var editing = false
    @State private var dismissed = false
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let shown = preview.shownAddress.map(LiveAddress.shown) ?? ""
        let others = (workspace.session(in: .main).flatMap { workspace.liveFound[$0.id] } ?? []).filter { $0 != preview.address }
        Group {
            if editing {
                TextField(text: $text, prompt: Text("输入地址").foregroundStyle(palette.ink3)) { Text("地址") }
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit {
                        if let url = LiveAddress.url(from: text) { go(url) }
                        editing = false
                    }
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { if !$1 { editing = false } }
                    .padding(.horizontal, Spacing.group)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.fill, in: .capsule)
                    .onAppear { focused = true }
                    .bubble(isPresented: Binding { !dismissed && !others.isEmpty } set: { if !$0 { dismissed = true } }) {
                        LiveCandidates(urls: others) { url in
                            go(url)
                            editing = false
                        }
                    }
            } else {
                Button {
                    text = shown
                    dismissed = false
                    editing = true
                } label: {
                    Text(verbatim: shown).lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, Spacing.group)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(.capsule)
                }
                .buttonStyle(PressStyle(.control))
                .help("改地址")
                .accessibilityLabel(Text("地址"))
                .accessibilityValue(Text(verbatim: shown))
            }
        }
        .font(Typography.secondary.weight(.medium))
        .foregroundStyle(palette.ink)
        .frame(height: ControlSize.compact.height)
        .frame(maxWidth: .infinity)
    }

    private func go(_ url: URL) { preview.retarget(.init(url: url, source: .typed)) }
}

/// 认出的其余服务：一行一个地址，不加说明。
private struct LiveCandidates: View {
    let urls: [URL]
    let pick: (URL) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(urls, id: \.self) { url in
                Button { pick(url) } label: {
                    Text(verbatim: LiveAddress.shown(url)).lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: RowMetrics.height, alignment: .leading)
                }
                .buttonStyle(.row)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .font(Typography.secondary.weight(.medium))
        .foregroundStyle(palette.ink)
        .padding(.horizontal, RowMetrics.bleed)
        .padding(.vertical, Spacing.tight)
    }
}

/// 载入进度：贴着玻璃栏下沿的一条细线（按栏的胶囊裁，两头随圆角收），载完淡出。
private struct LiveProgress: View {
    let value: Double
    let shown: Bool
    @Environment(\.palette) private var palette

    private static let thickness: CGFloat = 2
    /// 刚开始载、还没有进度时先露出的一截：一按下去就看得到在载。
    private static let start = 0.08

    var body: some View {
        GeometryReader { geometry in
            palette.signature
                .frame(width: geometry.size.width * max(Self.start, value), height: Self.thickness)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .animation(Motion.glide, value: value)
        }
        .clipShape(.capsule)
        .opacity(shown ? 1 : 0)
        .animation(Motion.fade, value: shown)
        .allowsHitTesting(false)
    }
}
#endif
