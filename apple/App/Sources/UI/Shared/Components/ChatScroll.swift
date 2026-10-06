import SwiftUI

/// "新消息"按钮的状态：往上翻离开底部后来了新内容才出现，回到底部消失。跟随到底不在这里——
/// 滚动视图的底部锚点（`defaultScrollAnchor(.bottom)`）在底部时随内容长高贴底，离开底部时保持阅读位置；内容不满一屏时贴着底部。
nonisolated struct ChatFollow: Equatable {
    private var atBottom = true
    private(set) var showsJump = false

    mutating func scrolled(atBottom: Bool) {
        self.atBottom = atBottom
        if atBottom { showsJump = false }
    }

    mutating func contentChanged() {
        if !atBottom { showsJump = true }
    }
}

/// 聊天式的滚动区（iOS 会话页、Mac 会话详情共用）：打开停在最新，停在底部时跟着新内容，往上翻后保持位置，
/// 来了新内容时可见区底部（输入框上方）浮出"新消息"，点它滚回底部。`followKey` 变了就算有新内容。减弱动态效果下滚动不做动画。
struct ChatScroll<Content: View, Key: Equatable>: View {
    let followKey: Key
    @ViewBuilder let content: Content
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var follow = ChatFollow()

    /// 离底部这么近算"在底部"。
    private static var bottomSlack: CGFloat { 24 }

    var body: some View {
        ScrollView { content }
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // containerSize 已扣掉上下 inset（导航栏、回复框）：可见区底边 = 偏移 + 顶部 inset + 容器高
                geometry.contentOffset.y + geometry.contentInsets.top + geometry.containerSize.height
                    >= geometry.contentSize.height - Self.bottomSlack
            } action: { _, atBottom in
                follow.scrolled(atBottom: atBottom)
            }
            .onChange(of: followKey) { follow.contentChanged() }
            .overlay(alignment: .bottom) {
                if follow.showsJump {
                    Button(action: toBottom) {
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

    private func toBottom() {
        if reduceMotion {
            position.scrollTo(edge: .bottom)
        } else {
            withAnimation(Motion.quick) { position.scrollTo(edge: .bottom) }
        }
    }
}
