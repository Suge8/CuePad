import SwiftUI

/// "新消息"按钮的状态：离开最新处后来了新内容才出现，回到最新处消失；在最新处时新内容由滚动区跟上（`ChatScroll`）。
nonisolated struct ChatFollow: Equatable {
    private(set) var atBottom = true
    private(set) var showsJump = false

    mutating func scrolled(atBottom: Bool) {
        self.atBottom = atBottom
        if atBottom { showsJump = false }
    }

    mutating func contentChanged() {
        if !atBottom { showsJump = true }
    }
}

extension EnvironmentValues {
    /// 在倒置的聊天滚动区里（iOS）：内容按新到旧给出，每一行用 `chatRow()` 转回正向。
    @Entry var chatInverted = false
}

extension View {
    /// 聊天滚动区里的一行：滚动区倒置时把它转回正向。
    func chatRow() -> some View { modifier(ChatRow()) }
}

private struct ChatRow: ViewModifier {
    @Environment(\.chatInverted) private var inverted
    func body(content: Content) -> some View { content.rotationEffect(.degrees(inverted ? 180 : 0)) }
}

/// 聊天式的滚动区（iOS 会话页、Mac 会话详情共用）：打开停在最新，停在最新处时跟着新内容，离开后保持阅读位置，
/// 来了新内容时可见区底部（输入框上方）浮出"新消息"，点它回到最新。`followKey` 变了就算有新内容。减弱动态效果下滚动不做动画。
///
/// iOS 上整个滚动区倒过来（转 180°，最新在偏移 0 处），内容按新到旧给出：打开、跟随、回到最新都是滚到偏移 0，
/// 懒加载从最新那条起排，估计高度只用在最旧的那一头、看不见的地方。正着排时最新在内容末端，它的位置要靠懒加载按估计高度
/// 推算：回答高矮悬殊（整页粘贴的长消息、长代码块）时打开或长距离滚回最新都会落在内容外、整页空白，在底部上推时内容高度还在变。
/// Mac 不倒置：滚轮不随画面翻转，倒置后滚动方向会反。
struct ChatScroll<Content: View, Key: Equatable>: View {
    let followKey: Key
    @ViewBuilder let content: Content
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition(edge: Self.newestEdge)
    @State private var follow = ChatFollow()

    #if os(iOS)
    private static var inverted: Bool { true }
    #else
    private static var inverted: Bool { false }
    #endif
    private static var newestEdge: Edge { inverted ? .top : .bottom }

    /// 离最新处这么近算"在最新处"。
    private static var slack: CGFloat { 24 }

    var body: some View {
        ScrollView { content }
            .scrollPosition($position)
            .defaultScrollAnchor(Self.inverted ? .top : .bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                if Self.inverted { return geometry.contentOffset.y + geometry.contentInsets.top <= Self.slack }
                // containerSize 已扣掉上下 inset：可见区底边 = 偏移 + 顶部 inset + 容器高
                return geometry.contentOffset.y + geometry.contentInsets.top + geometry.containerSize.height
                    >= geometry.contentSize.height - Self.slack
            } action: { _, atBottom in
                follow.scrolled(atBottom: atBottom)
            }
            .onChange(of: followKey) {
                // 倒置时在最新处就跟上去，离开了就保持位置、亮出按钮（正着排时由底部锚点贴底）
                if Self.inverted, follow.atBottom { toNewest() }
                follow.contentChanged()
            }
            .newestFirst(Self.inverted)
            .overlay(alignment: .bottom) {
                if follow.showsJump {
                    Button(action: toNewest) {
                        Label("新消息", systemImage: "arrow.down").font(.footnote.weight(.semibold)).foregroundStyle(palette.ink)
                            .padding(.horizontal, 14).frame(minHeight: 36)
                            .glass(in: .capsule, interactive: true)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .transition(.opacity)
                }
            }
            .animation(Motion.quick, value: follow.showsJump)
    }

    private func toNewest() {
        if reduceMotion {
            position.scrollTo(edge: Self.newestEdge)
        } else {
            withAnimation(Motion.quick) { position.scrollTo(edge: Self.newestEdge) }
        }
    }
}

private extension View {
    /// 把滚动区倒过来。转 180° 而不是上下镜像：镜像（行列式为负）时系统长按预览截到的是空白；代价是滚动条转到了左边，所以藏起来。
    /// 转过之后滚动区只占上下两条栏之间、不再延伸到栏下面，系统的滚动边缘效果也随之失效：不裁内容，对话照样从顶栏下面透出来
    /// （顶上本就不模糊）；底边自己淡出——从回复框上沿稍上方到伸进它下面的一段由实到无，再往下不画（系统的 soft 也是只淡出、不铺实底带）。
    @ViewBuilder func newestFirst(_ inverted: Bool) -> some View {
        if inverted {
            scrollIndicators(.hidden)
                .scrollClipDisabled()
                .rotationEffect(.degrees(180))
                .mask(alignment: .top) {
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: chatBottomFade.length)
                    }
                    .padding(.bottom, -chatBottomFade.below)
                    .ignoresSafeArea(edges: .top)
                }
                .environment(\.chatInverted, true)
        } else {
            self
        }
    }
}

/// 倒置的滚动区底边的淡出：共 `length`，其中 `below` 在回复框下面；余下的一小段在回复框上沿之上，比对话的底边距（14）短，停在最新处时不淡掉内容。
private let chatBottomFade = (length: CGFloat(44), below: CGFloat(32))
