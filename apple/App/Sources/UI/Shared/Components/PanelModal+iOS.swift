#if os(iOS)
import SwiftUI

@Observable
final class ModalHost {
    private(set) var modal: Modal?
    private(set) var hole: CGRect?

    func cover(_ entry: Modal, hole: CGRect? = nil) {
        if let modal, modal.token != entry.token { modal.close() }
        MainThreadWatch.shared.action(entry.popup == nil ? "open panel" : "open popup")
        modal = entry
        self.hole = hole
    }

    func uncover(_ token: UUID) {
        guard modal?.token == token else { return }
        MainThreadWatch.shared.action("close modal")
        modal = nil
        hole = nil
    }

    func reshape(_ token: UUID, hole: CGRect) {
        if modal?.token == token, self.hole != hole { self.hole = hole }
    }

    struct Modal {
        let token: UUID
        let close: ClosePanel
        var inPage = false
        var popup: Popup?
    }

    struct Popup {
        let source: CGRect
        let content: PanelContent
    }
}

extension View {
    func popup(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> some View) -> some View {
        modifier(PopupSlot(isPresented: isPresented, panel: content))
    }
}

struct ModalLayers: ViewModifier {
    let host: ModalHost

    func body(content: Content) -> some View {
        content
            .readerHidden(host.modal?.popup != nil)
            .overlay { ModalScrim(modal: host.modal, hole: host.hole) }
            .overlay { PopupLayer(modal: host.modal) }
            .environment(host)
            .debugExposesModals(host)
    }
}

private struct PopupSlot<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder let panel: () -> Panel
    @Environment(ModalHost.self) private var host: ModalHost?
    @Environment(\.self) private var environment
    @Environment(\.pageActive) private var active
    @State private var token = UUID()
    @State private var measured = Measured()
    @State private var shown = PanelContent()
    @AccessibilityFocusState private var focused: Bool

    private var close: ClosePanel { ClosePanel { [$isPresented] in $isPresented.wrappedValue = false } }
    private func view() -> AnyView { AnyView(panel().environment(\.closePanel, close).environment(\.self, environment)) }

    func body(content: Content) -> some View {
        content
            .feeds(shown, while: isPresented, view)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { measured.frame = $0 }
            .accessibilityFocused($focused)
            .accessibilityExpanded(isPresented)
            .onChange(of: isPresented, initial: true) { was, open in
                guard let host else { return }
                guard open else {
                    host.uncover(token)
                    if was { focused = true }
                    return
                }
                shown.view = view()
                host.cover(ModalHost.Modal(token: token, close: close, popup: ModalHost.Popup(source: measured.frame ?? .zero, content: shown)))
                Task {
                    await NextFrame.drawn()
                    AccessibilityNotification.ScreenChanged(nil).post()
                }
            }
            .onChange(of: active) { if !active { isPresented = false } }
            .onDisappear {
                isPresented = false
                host?.uncover(token)
            }
            .sensoryFeedback(.impact(weight: .light), trigger: isPresented)
    }

    private final class Measured {
        var frame: CGRect?
    }
}

struct PopupLayer: View {
    let modal: ModalHost.Modal?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let widest: CGFloat = 440

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            ZStack {
                if let modal, let popup = modal.popup {
                    let source = popup.source.offsetBy(dx: -frame.midX, dy: -frame.midY)
                    PanelBody(content: popup.content)
                        .frame(width: max(min(frame.width - 2 * Spacing.page, Self.widest), 0))
                        .frame(maxHeight: frame.height - 2 * Spacing.page)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .contain)
                        .accessibilityAddTraits(.isModal)
                        .accessibilityAction(.escape) { modal.close() }
                        .id(modal.token)
                        .transition(.modifier(
                            active: PopupGrow(progress: reduceMotion ? 1 : 0, source: source), identity: PopupGrow(progress: 1, source: source))
                            .combined(with: reduceMotion ? .opacity : .identity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(Motion.fading(Motion.nudge, reduceMotion: reduceMotion), value: modal?.popup == nil ? nil : modal?.token)
    }
}

private struct PopupGrow: ViewModifier, Animatable {
    var progress: CGFloat
    let source: CGRect

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private static let textFrom: CGFloat = 0.3

    func body(content: Content) -> some View {
        let shape = GrowShape(progress: progress, source: source)
        content
            .opacity(min(max((progress - Self.textFrom) / (1 - Self.textFrom), 0), 1))
            .clipShape(shape)
            .glass(in: shape)
            .opacity(min(progress / Self.glassFrom, 1))
    }

    private static let glassFrom: CGFloat = 0.15
}

nonisolated private struct GrowShape: Shape {
    var progress: CGFloat
    let source: CGRect

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let start = source.offsetBy(dx: rect.midX, dy: rect.midY)
        let p = min(max(progress, 0), 1)
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
        let frame = CGRect(x: lerp(start.minX, rect.minX), y: lerp(start.minY, rect.minY), width: lerp(start.width, rect.width), height: lerp(start.height, rect.height))
        let radius = lerp(min(start.width, start.height) / 2, Radius.sheet)
        return Path(roundedRect: frame, cornerRadius: min(radius, frame.height / 2), style: .continuous)
    }
}

struct ModalScrim: View {
    let modal: ModalHost.Modal?
    let hole: CGRect?
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            ZStack {
                if modal?.popup != nil {
                    palette.backdrop.allowsHitTesting(false).transition(.opacity)
                }
                if let modal {
                    Color.clear
                        .contentShape(Outside(hole: modal.inPage ? hole?.offsetBy(dx: -origin.x, dy: -origin.y) : nil), eoFill: true)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in modal.close() })
                        .overlay { Button("关闭") { modal.close() }.keyboardShortcut(.escape, modifiers: []).opacity(0).readerHidden(true) }
                        .transition(.identity)
                        .readerHidden(true)
                }
            }
        }
        .ignoresSafeArea()
        .animation(Motion.fade, value: modal?.popup != nil)
    }

    nonisolated private struct Outside: Shape {
        let hole: CGRect?

        func path(in rect: CGRect) -> Path {
            var path = Path(rect)
            if let hole { path.addRect(hole) }
            return path
        }
    }
}

#endif
