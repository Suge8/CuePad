#if os(macOS)
import AppKit
import SwiftUI

extension View {
    /// 会话里的文字可选中。Mac：鼠标悬停着的这一条才开选择；在某条里按下鼠标（开始拖选）后这条保持可选，选区留着，
    /// 直到在别处点击或在另一条里开始新的选择（`TextSelectionFocus`）。
    /// 文字选择（`textSelection`）每个文本都要另建一套排版，一屏回答全带上选择时点开会话的帧耗时多约三成。
    func selectableOnHover() -> some View { modifier(SelectOnHover()) }
}

#if DEBUG
/// 悬停进入与离开的次数（压力场景核对没有来回翻转的循环）。
@MainActor var hoverToggles = 0
#endif

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
        // 悬停由 AppKit 的跟踪区报，不用 `onHover`：开了选择的文字是平台视图，盖在指针下面时 SwiftUI 的悬停会立刻报"离开"，
        // 选择随之关掉、平台视图撤走、又报"进入"……每秒几千次，主线程被占死。跟踪区只看矩形，不受上面盖了什么影响。
        .background {
            HoverSensor { inside in
                #if DEBUG
                hoverToggles += 1
                #endif
                hovering = inside
                if inside { focus.hovered = id } else if focus.hovered == id { focus.hovered = nil }
            }
        }
        .onDisappear { if focus.hovered == id { focus.hovered = nil } }
    }
}

private struct HoverSensor: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> Sensor { Sensor() }
    func updateNSView(_ sensor: Sensor, context: Context) { sensor.changed = changed }

    final class Sensor: NSView {
        var changed: (Bool) -> Void = { _ in }
        private var inside = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
            // 内容在指针底下滚动或刚出现时，AppKit 不补发进入与离开：按指针此刻的位置对一次
            guard let window else { return set(false) }
            set(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
        }

        override func mouseEntered(with event: NSEvent) { set(true) }
        override func mouseExited(with event: NSEvent) { set(false) }

        private func set(_ value: Bool) {
            guard value != inside else { return }
            inside = value
            changed(value)
        }
    }
}
#endif
