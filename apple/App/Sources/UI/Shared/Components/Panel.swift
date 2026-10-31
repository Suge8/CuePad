import SwiftUI

/// 关掉自己所在的弹层（`panel`）。Mac 的窗口内浮层没有系统的 `dismiss`，两端的弹层内容都用它。
struct ClosePanel {
    let run: @MainActor () -> Void
    func callAsFunction() { run() }
}

extension EnvironmentValues {
    @Entry var closePanel = ClosePanel {}
    /// 这一层上面有开着的模态浮层（Mac 的窗口内浮层，`PanelHost.covers`；iOS 的弹层是系统的，恒为假）：
    /// 被盖住的输入框不要焦点——出现时的自动聚焦、焦点请求都先看它（盖上时交出见 `yieldsFocusWhenCovered`）。
    @Entry var panelCovered = false
}

enum PanelStyle: Equatable {
    /// 居中、模态（iOS 是 sheet）。
    case sheet
    /// 大块内容（预览）：iOS 全屏覆盖，Mac 同 `sheet`。
    case fullScreen
    /// 长出来的气泡（`BubbleFrame`，摆法在 `BubblePlacement`）：不压暗，点外面或 Esc 关、那一下照常落到下面；两端同一个样子（iOS 不是系统 sheet）。
    /// 从控件长出的在 Mac 上用 `bubble(isPresented:)`，它替控件量框。`width` 只有内容自己要宽的给（Mac 额度明细排两栏），手机按屏宽摆、不看它。
    case bubble(BubbleSource, width: CGFloat = BubblePlacement.width)

    /// 模态：压暗、拦下外面的点按（居中的 sheet 与全屏）。
    var modal: Bool {
        switch self {
        case .sheet, .fullScreen: true
        case .bubble: false
        }
    }
}

extension View {
    /// 弹层：调用处只给状态与内容，平台只换呈现。iOS 是系统 sheet（`fullScreen` 时全屏覆盖）；Mac 是窗口内浮层（`panelHost`）——
    /// AppKit 的窗口 sheet 开、关都把主线程关在约 300ms 的嵌套动画循环里，关的那一段整窗不出帧。Mac 上窗口内的浮层（⌘K、任务气泡、
    /// 挑任务、表单、确认框）都只走这里。内容用环境里的 `closePanel` 关自己。
    func panel(isPresented: Binding<Bool>, style: PanelStyle = .sheet, @ViewBuilder content: @escaping () -> some View) -> some View {
        panel(item: Binding { isPresented.wrappedValue ? Shown() : nil } set: { isPresented.wrappedValue = $0 != nil }, style: style) { _ in content() }
    }

    func panel<Item: Identifiable>(
        item: Binding<Item?>, style: PanelStyle = .sheet, @ViewBuilder content: @escaping (Item) -> some View
    ) -> some View {
        presentPanel(item: item, style: style, close: ClosePanel { item.wrappedValue = nil }, content: content)
    }
}

/// `panel(isPresented:)` 的身份：开着只有这一个。
private struct Shown: Identifiable { let id = true }
