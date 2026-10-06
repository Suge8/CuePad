import SwiftUI

/// 对话的滚动跟随：停在底部时新内容到来跟着到底；往上翻离开底部后不跟，新内容到来时出"新消息"按钮；
/// 点它（`jumped`）或自己翻回底部恢复跟随。
nonisolated struct ChatFollow: Equatable {
    private(set) var atBottom = true
    private(set) var unseen = false

    var showsJump: Bool { !atBottom && unseen }

    mutating func scrolled(atBottom: Bool) {
        self.atBottom = atBottom
        if atBottom { unseen = false }
    }

    /// 内容变了：返回要不要滚到底。
    mutating func contentChanged() -> Bool {
        if atBottom { return true }
        unseen = true
        return false
    }

    mutating func jumped() {
        atBottom = true
        unseen = false
    }
}

/// 聊天式的滚动区（iOS 会话页、Mac 会话详情共用）：打开停在最新，跟随规则见 `ChatFollow`，
/// "新消息"按钮浮在可见区底部（输入框上方）。`followKey` 变了就算有新内容。减弱动态效果下滚动不做动画。
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
            .onChange(of: followKey) {
                if follow.contentChanged() { toBottom() }
            }
            .overlay(alignment: .bottom) {
                if follow.showsJump {
                    Button {
                        follow.jumped()
                        toBottom()
                    } label: {
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
