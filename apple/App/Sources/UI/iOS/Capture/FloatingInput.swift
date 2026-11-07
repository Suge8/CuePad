#if os(iOS)
import SwiftUI

/// 浮在键盘上方的输入框（新会话、发给 Agent 共用）：不弹面板，背后的页面不压色（内容直接透在玻璃后面），浮起时随键盘升上来。
/// 点空白处或往下拖收起（输入框跟手往下走，没拖够就回位）。
struct FloatingInput<Content: View>: View {
    let isPresented: Bool
    let close: () -> Void
    @ViewBuilder let content: () -> Content
    /// 没拖够松手时弹回原位。
    @GestureState(resetTransaction: Transaction(animation: Motion.nudge)) private var drag: CGFloat = 0

    private static var dismissDistance: CGFloat { 60 }
    private static var maxWidth: CGFloat { 600 }

    var body: some View {
        ZStack(alignment: .bottom) {
            if isPresented {
                // 背后的页面不压色、不虚化（沉浸式，同回复框）：这一层透明，只接点按收起
                Color.clear.contentShape(.rect).ignoresSafeArea()
                    .gesture(DragGesture(minimumDistance: 0).onEnded { _ in dismiss() })
                    .readerHidden(true)
                content()
                    .frame(maxWidth: Self.maxWidth)
                    .padding(.horizontal, Spacing.group).padding(.bottom, Spacing.item)
                    .offset(y: drag)
                    .gesture(swipeDown)
                    .transition(.opacity)
                    .accessibilityAddTraits(.isModal)
                    .accessibilityAction(.escape, dismiss)
            }
        }
        // 只淡入淡出：位置跟着键盘走，自己不再加位移
        .animation(Motion.fade, value: isPresented)
        .modifier(KeyboardHold())
    }

    private var swipeDown: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($drag) { value, drag, _ in drag = max(0, value.translation.height) }
            .onEnded { value in
                if max(value.translation.height, value.predictedEndTranslation.height) > Self.dismissDistance { dismiss() }
            }
    }

    private func dismiss() {
        // 先放下键盘再移走输入框：等它移走后才失去焦点的话，键盘在它淡出之后才开始下落
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        close()
    }
}

#endif
