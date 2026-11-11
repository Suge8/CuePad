#if os(macOS)
import AppKit
import CueStore
import SwiftUI

extension View {
    func replyNotes(session: UUID, messages: [ChatMessage]) -> some View {
        modifier(ReplyNoteLayer(session: session, messages: messages))
    }
}

private struct ReplyNoteLayer: ViewModifier {
    let session: UUID
    let messages: [ChatMessage]
    @Environment(AppServices.self) private var services
    @State private var watch = WatchHandle()
    @State private var prose = ProseCache()
    @State private var float: Floating?

    /// 新的批注记下时才进草稿：回复框不在写的时候长高、把对话顶走。
    enum Floating: Equatable {
        case offer(ReplyNote, at: Spot)
        case editing(ReplyNote.Edit, at: Spot)
    }

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                guard let id = ReplyNote.id(of: url) else { return .systemAction }
                if let edit = services.settings.editReplyNote(id, in: session) {
                    float = .editing(edit, at: Spot(point: watch.view?.pointer ?? .zero))
                }
                return .handled
            })
            .background { WatchView(watch: watch, changed: selectionChanged) }
            .overlay {
                if let float {
                    Anchored(spot: float.at, gap: Self.lineHalf + Spacing.tight) { floating(float) }
                        .transition(.opacity)
                }
            }
            .animation(Motion.fade, value: float)
    }

    @ViewBuilder private func floating(_ float: Floating) -> some View {
        switch float {
        case .offer(let note, let at):
            Button { begin(note, at: at) } label: {
                Label("批注", icon: .said)
                    .font(Typography.caption.weight(.semibold))
                    .padding(.horizontal, Spacing.inset).frame(height: 28)
                    .contentShape(.capsule)
            }
            .buttonStyle(PressStyle())
            .glass(in: .capsule, interactive: true)
            .help("批注这段，随下一句发出")
        case .editing(let edit, _):
            NoteEditor(note: edit.note) { text in
                let settings = services.settings
                if let text {
                    settings.save(edit, text: text, order: messages.map(\.id), in: session)
                } else if !edit.fresh {
                    settings.removeReplyNote(edit.note.id, in: session)
                }
                self.float = nil
            }
        }
    }

    private static let lineHalf: CGFloat = {
        let font = Typography.readingFont
        return (font.ascender - font.descender + font.leading + Typography.readingLineSpacing) / 2
    }()

    private func selectionChanged(_ selection: SelectionWatch.Selection?) {
        if case .editing = float { return }
        float = selection.flatMap { selection in
            let frame = selection.frame, half = Self.lineHalf
            let point = CGPoint(
                x: min(max(selection.at.x, frame.minX), frame.maxX),
                y: min(max(selection.at.y, frame.minY + half), frame.maxY - half))
            return note(for: selection).map { .offer($0, at: Spot(point: point, columns: frame.minX...frame.maxX)) }
        }
    }

    private func note(for selection: SelectionWatch.Selection) -> ReplyNote? {
        for message in messages.reversed() where message.role == .known(.pi) {
            guard let run = prose.texts(of: message).firstIndex(of: selection.text) else { continue }
            let quote = (selection.text as NSString).substring(with: selection.range)
            return ReplyNote(entry: message.id, run: run, location: selection.range.location, quote: quote)
        }
        return nil
    }

    private func begin(_ note: ReplyNote, at: Spot) {
        float = .editing(services.settings.editReplyNote(at: note, in: session), at: at)
    }
}

private struct Spot: Equatable {
    var point: CGPoint
    var columns: ClosedRange<CGFloat> = -.infinity ... .infinity
}

private extension ReplyNoteLayer.Floating {
    var at: Spot {
        switch self {
        case .offer(_, let at), .editing(_, let at): at
        }
    }
}

/// 字先留在这里、记下时才写进草稿：打字时对话里的高亮与回复框不跟着重算。
/// `done` 只调一次（收起时还会失去焦点）：给字是记下，nil 是不要这条。
private struct NoteEditor: View {
    let note: ReplyNote
    let done: (String?) -> Void
    @State private var text: String
    @State private var settled = false
    @FocusState private var focused: Bool
    @Environment(\.palette) private var palette

    init(note: ReplyNote, done: @escaping (String?) -> Void) {
        self.note = note
        self.done = done
        _text = State(initialValue: note.note)
    }

    private static let width: CGFloat = 300
    private static let shape = RoundedRectangle(cornerRadius: Radius.card)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
            Image(.said).font(Typography.secondary).foregroundStyle(palette.ink2).accessibilityHidden(true)
            TextField(String(localized: "写批注，↩ 挂到下一句"), text: $text, palette: palette, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Typography.secondary).foregroundStyle(palette.ink)
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit(submit)
        }
        .padding(.horizontal, Spacing.inset).padding(.vertical, Spacing.group)
        .frame(width: Self.width, alignment: .leading)
        .glass(in: Self.shape)
        .resignsFocusOnOutsideClick()
        .onExitCommand { settle(note.note.isEmpty ? nil : note.note) }
        .onAppear { focused = true }
        .onChange(of: focused) { if !focused { commit() } }
    }

    private func submit() {
        guard note.note.isEmpty, text.allSatisfy(\.isWhitespace) else { return commit() }
        focused = true
    }

    private func commit() {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        settle(text.isEmpty ? nil : text)
    }

    private func settle(_ result: String?) {
        guard !settled else { return }
        settled = true
        done(result)
    }
}

/// 默认在这一行下面：拖选多是从上往下，松手处是选区末尾，往下放不遮住选中的字。
private struct Anchored: Layout {
    let spot: Spot

    let gap: CGFloat
    private static let margin: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let size = child.sizeThatFits(.unspecified), point = spot.point
        let left = max(spot.columns.lowerBound, Self.margin), right = min(spot.columns.upperBound, bounds.width - Self.margin)
        let x = max(left, min(point.x - size.width / 2, right - size.width))
        let below = point.y + gap + size.height <= bounds.height - Self.margin
        let y = below ? point.y + gap : max(Self.margin, point.y - gap - size.height)
        child.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
    }
}

/// 每条回答渲染出的可选文字（`MarkdownText.proseTexts`）：只在松开鼠标有选区时按需算，按消息记住（回答写完就不变，变了按字重算）。
private final class ProseCache {
    private var texts: [UUID: (source: String, prose: [String])] = [:]

    func texts(of message: ChatMessage) -> [String] {
        if let hit = texts[message.id], hit.source == message.text { return hit.prose }
        let prose = MarkdownText.proseTexts(message.text)
        texts[message.id] = (message.text, prose)
        return prose
    }
}

private final class WatchHandle {
    weak var view: SelectionWatch?
}

private struct WatchView: NSViewRepresentable {
    let watch: WatchHandle
    let changed: (SelectionWatch.Selection?) -> Void

    func makeNSView(context: Context) -> SelectionWatch {
        let view = SelectionWatch()
        watch.view = view
        return view
    }

    func updateNSView(_ view: SelectionWatch, context: Context) { view.changed = changed }
}

/// 读选区：SwiftUI 的可选文字（`textSelection`）在 Mac 上每个 `Text` 是一个交互视图，读屏接口（公开）给出它整段的字与选区，
/// 不经剪贴板、不碰私有类名。拖选时它不成为第一响应者，在别段选字时先前那段的选区也不清掉（macOS 26 实测），所以按下时记下各段的选区，
/// 松开后找这一下选区变了的那段。读屏接口给不出选区的位置（量出来是零），所以浮层挂在指针处。
/// 否决的：每条回答换成 TextKit 文本视图（长对话太重）、发"复制"去取（覆盖剪贴板）、每块挂悬停跟踪（`docs/ui.md`）。
private final class SelectionWatch: NSView {
    struct Selection {
        let text: String
        let range: NSRange
        let at: CGPoint
        let frame: CGRect
    }

    var changed: (Selection?) -> Void = { _ in }
    private var monitor: Any?
    private var before: [ObjectIdentifier: NSRange] = [:]

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .scrollWheel, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func handle(_ event: NSEvent) {
        guard event.window === window else { return }
        switch event.type {
        case .leftMouseDown:
            before = Dictionary(texts.map { (ObjectIdentifier($0), $0.accessibilitySelectedTextRange()) }) { first, _ in first }
        case .leftMouseUp:
            let point = event.locationInWindow, before = before
            // 选区在这次点按处理完才定下：下一轮再读
            Task { [weak self] in
                guard let self else { return }
                changed(selection(near: point) { before[ObjectIdentifier($0)] != $1 })
            }
        default:
            changed(nil)
        }
    }

    private func selection(near point: NSPoint, counts: (NSView, NSRange) -> Bool) -> Selection? {
        let candidates = texts.compactMap { view -> (Selection, CGFloat)? in
            let range = view.accessibilitySelectedTextRange()
            guard range.length > 0, counts(view, range), let text = view.accessibilityValue() as? String, NSMaxRange(range) <= text.utf16.count
            else { return nil }
            let frame = view.convert(view.bounds, to: nil)
            let distance = hypot(max(frame.minX - point.x, 0, point.x - frame.maxX), max(frame.minY - point.y, 0, point.y - frame.maxY))
            let origin = local(NSPoint(x: frame.minX, y: frame.maxY))
            return (Selection(text: text, range: range, at: local(point), frame: CGRect(origin: origin, size: frame.size)), distance)
        }
        return candidates.min { $0.1 < $1.1 }?.0
    }

    private var texts: [NSView] {
        window?.contentView.map { Self.texts(in: $0, within: convert(bounds, to: nil)) } ?? []
    }

    private static func texts(in view: NSView, within area: NSRect) -> [NSView] {
        guard view.convert(view.bounds, to: nil).intersects(area) else { return [] }
        let own: [NSView] = !(view is NSText) && view.accessibilityValue() is String ? [view] : []
        return own + view.subviews.flatMap { texts(in: $0, within: area) }
    }

    var pointer: CGPoint { local(window?.mouseLocationOutsideOfEventStream ?? .zero) }

    private func local(_ point: NSPoint) -> CGPoint {
        let inside = convert(point, from: nil)
        return CGPoint(x: inside.x, y: isFlipped ? inside.y : bounds.height - inside.y)
    }
}
#endif
