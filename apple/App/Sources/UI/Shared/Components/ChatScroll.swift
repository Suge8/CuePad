import SwiftUI

/// 贴着最新（规则同 use-stick-to-bottom）：只有用户自己滚走才解除贴底，回到最新处（自己滚回、点"新消息"、点顶栏）重新贴上；
/// 输入框长高、键盘弹出这类不是用户滚动带来的位移不解除。解除后来了新内容才出"新消息"。
nonisolated struct ChatFollow: Equatable {
    private(set) var atNewest = true
    private(set) var showsJump = false
    /// 请滚动区回到最新的次数（`jumpToNewest`）：滚动区看到它变了就滚过去。
    private(set) var jumps = 0
    /// 请滚动区跳到的那一条（`jump(to:)`）。
    private(set) var target: Target?
    /// 用户正拖着或甩着滚动区（滚动区写入）。
    var scrolling = false

    struct Target: Equatable {
        let id: UUID
        let request = UUID()
    }

    mutating func scrolled(nearNewest: Bool, byUser: Bool) {
        if nearNewest {
            atNewest = true
            showsJump = false
        } else if byUser {
            atNewest = false
        }
    }

    mutating func contentChanged() {
        if !atNewest { showsJump = true }
    }

    mutating func jumpToNewest() { jumps += 1 }

    /// 跳到某一条去读：不再贴着最新（跳到的就在最新处时，滚到后会重新贴上）。
    mutating func jump(to id: UUID) {
        atNewest = false
        target = Target(id: id)
    }
}

extension EnvironmentValues {
    /// 在倒置的聊天滚动区里（iOS）：内容按新到旧给出，每一行用 `chatRow()` 转回正向。
    @Entry var chatInverted = false
    /// 倒置的聊天滚动区底下（回复框与键盘）占的高：对话在懒加载栈里以最新那头的一行空白让出它（见 `ChatScroll`）。
    @Entry var chatBottomSpace: CGFloat = 0
    /// 刚跳到的那条你的话：短暂描一圈（刻度滑条）。
    @Entry var chatHighlight: UUID?
}

extension View {
    /// 聊天滚动区里的一行：滚动区倒置时把它转回正向。
    func chatRow() -> some View { modifier(ChatRow()) }
}

private struct ChatRow: ViewModifier {
    @Environment(\.chatInverted) private var inverted
    func body(content: Content) -> some View { content.rotationEffect(.degrees(inverted ? 180 : 0)) }
}

/// 聊天式的滚动区（iOS 会话页、Mac 会话详情共用）：打开停在最新，贴着最新时跟着新内容与底下输入框的长高、键盘的弹出，
/// 用户滚走后这些都不再挪动正在读的内容，来了新内容时可见区底部（输入框上方）浮出"新消息"，点它回到最新（`ChatFollow`）。
/// `followKey` 变了就算有新内容。减弱动态效果下滚动不做动画。
///
/// iOS 上整个滚动区倒过来（转 180°，最新在偏移 0 处），内容按新到旧给出：打开、跟随、回到最新都是滚到偏移 0，
/// 懒加载从最新那条起排，估计高度只用在最旧的那一头、看不见的地方。正着排时最新在内容末端，它的位置要靠懒加载按估计高度
/// 推算：回答高矮悬殊（整页粘贴的长消息、长代码块）时打开或长距离滚回最新都会落在内容外、整页空白。
/// Mac 不倒置：滚轮不随画面翻转，倒置后滚动方向会反。
struct ChatScroll<Content: View, Key: Equatable>: View {
    let followKey: Key
    private let external: Binding<ChatFollow>?
    private let content: Content
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition(edge: Self.newestEdge)
    @State private var own = ChatFollow()
    /// 底下回复框与键盘占的高（iOS）。
    @State private var below: CGFloat = 0

    /// `follow`：页面要据贴底与否改别处（收起顶栏、输入框）时由页面持有；不给就自己持有。
    init(followKey: Key, follow: Binding<ChatFollow>? = nil, @ViewBuilder content: () -> Content) {
        self.followKey = followKey
        external = follow
        self.content = content()
    }

    private var follow: Binding<ChatFollow> { external ?? $own }

    #if os(iOS)
    private static var inverted: Bool { true }
    #else
    private static var inverted: Bool { false }
    #endif
    private static var newestEdge: Edge { inverted ? .top : .bottom }

    /// 离最新处这么近算"在最新处"。
    private static var slack: CGFloat { 24 }

    var body: some View {
        // 滚动区自己铺到屏幕底（见 `scroll`），外框仍是两条栏之间：浮在上面的"新消息"与页面叠的东西都按可见区摆
        Color.clear
            .background { scroll }
            .overlay(alignment: .bottom) {
                if follow.wrappedValue.showsJump {
                    Button { follow.wrappedValue.jumpToNewest() } label: {
                        Label("新消息", systemImage: "arrow.down").font(.footnote.weight(.semibold)).foregroundStyle(palette.ink)
                            .padding(.horizontal, 14).frame(minHeight: 36)
                            .glass(in: .capsule, interactive: true)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .transition(.opacity)
                }
            }
            .animation(Motion.quick, value: follow.wrappedValue.showsJump)
            .onChange(of: follow.wrappedValue.jumps) { toNewest() }
            .onChange(of: follow.wrappedValue.target) { _, target in
                guard let target else { return }
                withAnimation(reduceMotion ? nil : Motion.quick) { position.scrollTo(id: target.id, anchor: .center) }
            }
    }

    @ViewBuilder private var scroll: some View {
        #if os(iOS)
        // 滚动区铺到屏幕底、不随底下的回复框与键盘缩放：滚动区缩放时可见内容跟着框底一起挪，看历史时一点输入框、多打一行，
        // 正在读的就被往上挤。它们占的高由对话在最新那头的一行空白让出：懒加载栈在可见区以外的行变高时补偏移，正在读的纹丝不动；
        // 贴着最新时滚动区停在起点，最新一行跟着回复框上沿走（离起点还差一点时补滚过去）
        tracked(ScrollView { content.environment(\.chatBottomSpace, below) })
            .onChange(of: below) { if follow.wrappedValue.atNewest { position.scrollTo(edge: Self.newestEdge) } }
            .newestFirst(below: below)
            .ignoresSafeArea(edges: .bottom)
            // 铺满后伸进底下的那一段就是回复框与键盘占的高
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { below = $0 }
        #else
        tracked(ScrollView { content }).defaultScrollAnchor(.bottom)
        #endif
    }

    private func tracked(_ scroll: some View) -> some View {
        scroll
            .scrollPosition($position)
            .onScrollPhaseChange { _, phase in follow.wrappedValue.scrolling = phase == .interacting || phase == .decelerating }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                if Self.inverted { return geometry.contentOffset.y + geometry.contentInsets.top <= Self.slack }
                // containerSize 已扣掉上下 inset：可见区底边 = 偏移 + 顶部 inset + 容器高
                return geometry.contentOffset.y + geometry.contentInsets.top + geometry.containerSize.height
                    >= geometry.contentSize.height - Self.slack
            } action: { _, near in
                follow.wrappedValue.scrolled(nearNewest: near, byUser: follow.wrappedValue.scrolling)
            }
            .onChange(of: followKey) {
                // 倒置时贴着最新就跟上去，没贴着就保持位置、亮出按钮（正着排时由底部锚点贴底）
                if Self.inverted, follow.wrappedValue.atNewest { toNewest() }
                follow.wrappedValue.contentChanged()
            }
    }

    private func toNewest() {
        if reduceMotion {
            position.scrollTo(edge: Self.newestEdge)
        } else {
            withAnimation(Motion.quick) { position.scrollTo(edge: Self.newestEdge) }
        }
    }
}

#if os(iOS)
private extension View {
    /// 把滚动区倒过来。转 180° 而不是上下镜像：镜像（行列式为负）时系统长按预览截到的是空白；代价是滚动条转到了左边，所以藏起来。
    /// 系统的滚动边缘效果按没转过的方向画：滚动区尺寸一变，它会把整片对话糊成一帧模糊（打字换行时一闪），所以关掉；
    /// 不裁内容，对话照样从顶栏下面透出来（顶上本就不模糊）；底边自己淡出——`below` 是底下回复框（与键盘）占的高，
    /// 从回复框上沿稍上方到伸进它下面的一段由实到无，再往下不画（系统的 soft 也是只淡出、不铺实底带）。
    func newestFirst(below: CGFloat) -> some View {
        scrollIndicators(.hidden)
            .scrollEdgeEffectHidden()
            .scrollClipDisabled()
            .defaultScrollAnchor(.top)
            .rotationEffect(.degrees(180))
            .mask(alignment: .top) {
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: chatBottomFade.length)
                    Color.clear.frame(height: max(0, below - chatBottomFade.below))
                }
                .ignoresSafeArea(edges: .top)
            }
            .environment(\.chatInverted, true)
    }
}

/// 倒置的滚动区底边的淡出：共 `length`，其中 `below` 在回复框下面；余下的一小段在回复框上沿之上，比对话的底边距（14）短，停在最新处时不淡掉内容。
private let chatBottomFade = (length: CGFloat(44), below: CGFloat(32))
#endif
