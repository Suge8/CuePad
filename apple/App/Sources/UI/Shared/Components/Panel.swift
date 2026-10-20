import SwiftUI

/// 关掉自己所在的弹层（`panel`）。Mac 的窗口内浮层没有系统的 `dismiss`，两端的弹层内容都用它。
struct ClosePanel {
    let run: @MainActor () -> Void
    func callAsFunction() { run() }
}

extension EnvironmentValues {
    @Entry var closePanel = ClosePanel {}
}

/// 弹层的摆法。
enum PanelStyle {
    /// Mac 上居中浮层的圆角（内容自己画底时也用它，如 ⌘K 的玻璃）。
    static let radius: CGFloat = 16

    /// 居中、模态（iOS 是 sheet）。
    case sheet
    /// 大块内容（预览）：iOS 全屏覆盖，Mac 同 `sheet`。
    case fullScreen
    /// Mac 右上角的面板（任务）：页面轻轻压暗，同系统 popover——点外面任意处或 Esc 关，那一下照常落到下面。
    case side
}

extension View {
    /// 弹层：调用处只给状态与内容，平台只换呈现。iOS 是系统 sheet（`fullScreen` 时全屏覆盖）；Mac 是窗口内浮层（`panelHost`）——
    /// AppKit 的窗口 sheet 开、关都把主线程关在约 300ms 的嵌套动画循环里，关的那一段整窗不出帧。Mac 上窗口内的浮层（⌘K、任务面板、
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
