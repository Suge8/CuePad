#if os(iOS)
import CueEditor
import SwiftUI
import UIKit

@Observable
final class IOSEditorHandle {
    @ObservationIgnored fileprivate weak var view: CueTextView?
    let spot = AttachmentSpot()
    @ObservationIgnored fileprivate var refocus = false
    fileprivate var focusChanges = 0
    var source: ComposerSource?

    var text: String? { view?.storedText }
    var selection: String? { view?.selectedStoredText }
    func insert(_ files: [IncomingFile]) { view?.insert(files) }
    var focused: Bool {
        _ = focusChanges
        return view?.isFirstResponder == true
    }
    func focus() { view?.becomeFirstResponder() }
    func replace(_ text: String) {
        guard let view else { return }
        let location = view.selectedRange.location
        view.storedText = text
        view.selectedRange = NSRange(location: min(location, (view.text as NSString).length), length: 0)
    }
}

struct IOSEditorHost: UIViewRepresentable {
    let initialText: String
    let theme: CueEditorTheme
    let handle: IOSEditorHandle
    let onChange: (String) -> Void
    var selectionActions: [CueSelectionAction] = []
    var onError: (any Error) -> Void = { _ in }
    var fits = false
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    var editable = true
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @Environment(\.openPreview) private var openPreview

    final class Coordinator {
        var watching: Task<Void, Never>?
        var focus: [any NSObjectProtocol] = []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private static let settle: Duration = .milliseconds(650)

    func makeUIView(context: Context) -> CueTextView {
        let view = CueTextView(files: services.store.files, theme: theme)
        view.storedText = initialText
        context.coordinator.watching = AttachmentLooks.follow(services, in: view)
        context.coordinator.focus = [UITextView.textDidBeginEditingNotification, UITextView.textDidEndEditingNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [handle] _ in
                MainActor.assumeIsolated { handle.focusChanges += 1 }
            }
        }
        view.accessibilityLabel = String(localized: "正文")
        // 同 `RouteView` 的柔边：那里的 `scrollEdgeEffectStyle` 传不进 UIKit 的滚动视图，默认是带分隔线的实底，滚进页头时一刀切开
        view.topEdgeEffect.style = .soft
        if fits {
            view.isScrollEnabled = false
            view.alwaysBounceVertical = false
        }
        handle.view = view
        if initialText.isEmpty {
            DispatchQueue.main.async {
                // 推入的转场快停稳了再接键盘：半路接（约 0.45 秒处）转场最后一截被截断，快铺满的页一帧跳到位；等它报完成又要 1.2 秒，键盘来得太晚（都是录屏逐帧量的）
                let controller = sequence(first: view as UIResponder, next: \.next).lazy.compactMap { $0 as? UIViewController }.first
                guard controller?.transitionCoordinator != nil else { return _ = view.becomeFirstResponder() }
                Task {
                    guard (try? await Task.sleep(for: Self.settle)) != nil else { return }
                    view.becomeFirstResponder()
                }
            }
        }
        if let range = DebugHooks.args.selection {
            DebugHooks.later(.milliseconds(500)) {
                view.becomeFirstResponder()
                view.selectedRange = range
            }
        }
        return view
    }

    func updateUIView(_ view: CueTextView, context: Context) {
        // 光标跟随避开的是滚动 inset；只给正文末尾留白，UIKit 输入时仍会把光标推到纸边。
        if view.contentInset.bottom != bottomInset { view.contentInset.bottom = bottomInset }
        if view.contentInset.top != topInset {
            let atTop = view.contentOffset.y <= -view.adjustedContentInset.top
            view.contentInset.top = topInset
            if atTop { view.contentOffset.y = -view.adjustedContentInset.top }
        }
        view.onChange = onChange
        view.selectionActions = selectionActions
        view.onError = onError
        view.onOpenAttachment = { [weak view, handle, workspace, openPreview] key, name, picture in
            guard let view else { return }
            let frame = picture.offsetBy(dx: -view.contentOffset.x, dy: -view.contentOffset.y)
            handle.spot.open(DraftFile(key: key, name: name), at: frame, in: workspace, with: openPreview)
        }
        if view.isEditable != editable { setEditable(view) }
        if view.theme != theme {
            view.theme = theme
        }
    }

    private func setEditable(_ view: CueTextView) {
        if !editable {
            handle.refocus = view.isFirstResponder
            view.resignFirstResponder()
        }
        view.isEditable = editable
        view.isSelectable = editable
        view.isAccessibilityElement = editable
        view.isUserInteractionEnabled = editable
        if editable, handle.refocus { view.becomeFirstResponder() }
    }

    static func dismantleUIView(_ view: CueTextView, coordinator: Coordinator) {
        coordinator.watching?.cancel()
        coordinator.focus.forEach(NotificationCenter.default.removeObserver)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: CueTextView, context: Context) -> CGSize? {
        guard fits, let width = proposal.width else { return nil }
        return CGSize(width: width, height: uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }
}
#endif
