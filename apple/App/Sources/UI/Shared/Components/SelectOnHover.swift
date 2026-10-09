import SwiftUI
#if os(macOS)
import AppKit
#endif

extension View {
    /// 会话里的文字可选中。Mac：鼠标悬停着的这一条才开选择；在某条里按下鼠标（开始拖选）后这条保持可选，选区留着，
    /// 直到在别处点击或在另一条里开始新的选择（`TextSelectionFocus`）。
    /// 文字选择（`textSelection`）每个文本都要另建一套排版，一屏回答全带上选择时点开会话的帧耗时多约三成。
    func selectableOnHover() -> some View {
        #if os(macOS)
        modifier(SelectOnHover())
        #else
        textSelection(.enabled)
        #endif
    }
}

#if os(macOS)
/// 当前保留选区的那一条（全 App 只有一个）：鼠标按下时记成指针下悬停着的那一条，没有悬停的（点在别处）就清空。
@MainActor @Observable
private final class TextSelectionFocus {
    static let shared = TextSelectionFocus()

    private(set) var current: UUID?
    @ObservationIgnored var hovered: UUID?
    @ObservationIgnored private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [unowned self] event in
            MainActor.assumeIsolated { current = hovered }
            return event
        }
    }
}

private struct SelectOnHover: ViewModifier {
    @State private var id = UUID()
    @State private var hovering = false
    private let focus = TextSelectionFocus.shared

    func body(content: Content) -> some View {
        Group {
            if hovering || focus.current == id { content.textSelection(.enabled) } else { content }
        }
        .onHover { inside in
            hovering = inside
            if inside { focus.hovered = id } else if focus.hovered == id { focus.hovered = nil }
        }
        .onDisappear { if focus.hovered == id { focus.hovered = nil } }
    }
}
#endif
