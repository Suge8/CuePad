import CueStore
import SwiftUI

/// 浮在网页上的玻璃栏：重新载入（载入中是停止）、地址、点选、手机宽、在浏览器里打开；载入进度是贴着下沿的一条细线。
/// 宽屏上末端是并排里每一块都有的 ×（`PaneClose`），与左边会话栏头上打开它的那颗钮（`WideSessionTitle`）是同一个开合。
/// 宽屏上开头是"放大"（`Workspace.toggleLiveFill`）：这块屏长到盖过左边的会话，那时这颗换成"放回右半"（左边栏头那颗钮被盖住，点不到）。
/// iPad 同 Mac，只是没有手机宽与在浏览器里打开（Safari 连不到 Mac 的 localhost）；手机上是收起、后退、前进、地址、重新载入、点选（收起只在这里：页头那颗钮被这一页盖住了）。
struct LiveBar: View {
    let preview: LivePreview
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let loading = preview.isLoading && preview.phase == .live
        let narrow = workspace.layout == .narrow
        HStack(spacing: Spacing.hair) {
            if !narrow {
                let filling = workspace.liveFill != nil
                tool(filling ? "放回右半" : "放大", icon: filling ? .shrink : .enlarge) { workspace.toggleLiveFill() }
            }
            if narrow {
                tool("收起活预览", icon: .close) { workspace.toggleLivePreview() }
                tool("后退", icon: .back) { preview.web.goBack() }
                    .disabled(!preview.canGoBack)
                tool("前进", icon: .forward) { preview.web.goForward() }
                    .disabled(!preview.canGoForward)
            }
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
            #if os(macOS)
            tool(preview.viewport == .phone ? "铺满" : "手机宽度", icon: .phoneWidth, on: preview.viewport == .phone) {
                withAnimation(Motion.spatial(Motion.travel, reduceMotion: reduceMotion)) { preview.viewport = preview.viewport == .phone ? .fill : .phone }
            }
            tool("在浏览器里打开", icon: .openInBrowser) { if let url = preview.shownAddress { LivePreview.openOutside(url) } }
                .disabled(preview.shownAddress == nil)
            #endif
            if !narrow { PaneClose { workspace.toggleLivePreview() } }
        }
        .padding(.horizontal, PaneClose.inset)
        .frame(height: Chrome.control)
        .overlay { LiveProgress(value: preview.progress, shown: loading) }
        .glass(in: .capsule)
    }

    private func tool(_ label: LocalizedStringResource, icon: Icon, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(icon).foregroundStyle(on ? palette.signature : palette.ink) }
            .buttonStyle(ControlButtonStyle(kind: .icon, size: .compact))
            .toggledOn(on)
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
        let others = (preview.serving ?? []).filter { $0 != preview.address }
        Group {
            if editing {
                TextField(text: $text, prompt: Text("输入地址").foregroundStyle(palette.ink3)) { Text("地址") }
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit {
                        if let url = LiveAddress.url(from: text) { go(url) }
                        editing = false
                    }
                    #if os(macOS)
                    .onExitCommand { editing = false }
                    #endif
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
                        // 两边让出状态标的位置：它来去时地址不挪
                        .padding(.horizontal, Spacing.group + LiveDriven.width)
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
        .overlay(alignment: .leading) {
            if preview.driven, !editing { LiveDriven().padding(.leading, Spacing.group).transition(.opacity) }
        }
        .animation(Motion.fade, value: preview.driven)
    }

    private func go(_ url: URL) { preview.retarget(.init(url: url, source: .typed)) }
}

/// Agent 这几秒在看、在点这一页（`LivePreview.driven`）：地址前面那个会话在跑时的状态标，压在地址框的边上，不占栏里的位置。
private struct LiveDriven: View {
    static let size: CGFloat = 7
    static var width: CGFloat { size * 1.8 }

    var body: some View {
        StateDot(shown: SessionShown(status: .working(.thinking)), size: Self.size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Agent 正在操作这个页面"))
            .help(Text("Agent 正在操作这个页面"))
    }
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
