#if os(iOS)
import CueStore
import SwiftUI

/// "写"（浮起随手记）的名字与图标：iPhone 标签栏右边的圆钮与 iPad 工具栏共用。图标不用 square.and.pencil：
/// 项目页的"新建卡片"是它，两个按钮会同时在屏上。
enum WriteEntry {
    static let title = "记一笔"
    static let symbol = "pencil.line"
}

/// 浮在键盘上方的输入框（随手记、新会话、发给 Agent 共用）：不弹面板，背后的页面不压色（内容直接透在玻璃后面），浮起时随键盘升上来。
/// 点空白处或往下拖收起（输入框跟手往下走，没拖够就回位）；里面在忙时（内容标了 `floatingInputLocked`）不收起。
struct FloatingInput<Content: View>: View {
    let isPresented: Bool
    let close: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var locked = false
    /// 没拖够松手时弹回原位。
    @GestureState(resetTransaction: Transaction(animation: Motion.snappy)) private var drag: CGFloat = 0

    /// 往下拖过这么多（或甩出去会过）就收起。
    private static var dismissDistance: CGFloat { 60 }
    private static var maxWidth: CGFloat { 600 }

    var body: some View {
        ZStack(alignment: .bottom) {
            if isPresented {
                // 背后的页面不压色、不虚化（沉浸式，同回复框）：这一层透明，只接点按收起
                Color.clear.contentShape(.rect).ignoresSafeArea()
                    .gesture(DragGesture(minimumDistance: 0).onEnded { _ in dismiss() })
                    .accessibilityHidden(true)
                content()
                    .environment(\.composerInk, .solid)
                    .frame(maxWidth: Self.maxWidth)
                    .padding(.horizontal, 12).padding(.bottom, 8)
                    .offset(y: drag)
                    .gesture(swipeDown)
                    .transition(.opacity)
                    .onPreferenceChange(FloatingInputLock.self) { locked = $0 }
                    .accessibilityAddTraits(.isModal)
                    .accessibilityAction(.escape, dismiss)
            }
        }
        // 只淡入淡出：位置跟着键盘走，自己不再加位移
        .animation(Motion.quick, value: isPresented)
    }

    private var swipeDown: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($drag) { value, drag, _ in if !locked { drag = max(0, value.translation.height) } }
            .onEnded { value in
                if max(value.translation.height, value.predictedEndTranslation.height) > Self.dismissDistance { dismiss() }
            }
    }

    private func dismiss() {
        guard !locked else { return }
        // 先放下键盘再移走输入框：等它移走后才失去焦点的话，键盘在它淡出之后才开始下落
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        close()
    }
}

private struct FloatingInputLock: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

extension View {
    /// 浮起的输入框里在忙（如新会话已发出、等 Mac 开好）：点空白处与下拖不收起。
    func floatingInputLocked(_ locked: Bool) -> some View { preference(key: FloatingInputLock.self, value: locked) }
}
#endif
