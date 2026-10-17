#if os(macOS)
import AppKit
import CueStore
import SwiftUI

extension View {
    /// 会话页的批注层：在 Agent 的回答里选中一段、松开鼠标，指针下方浮出"批注"；点它就地写一句，写下的进这个会话回复框的草稿
    /// （`AppSettings.replyNotes`），随下一句发出（`ReplyNote`）。点对话里的高亮改那一条。
    /// 选区怎么读、为什么挂在指针处见 `SelectionWatch`。
    func replyNotes(session: UUID, messages: [PiChatMessage]) -> some View {
        modifier(ReplyNoteLayer(session: session, messages: messages))
    }
}

private struct ReplyNoteLayer: ViewModifier {
    let session: UUID
    let messages: [PiChatMessage]
    @Environment(AppServices.self) private var services
    @State private var watch = WatchHandle()
    @State private var prose = ProseCache()
    @State private var float: Floating?

    /// 浮在对话上的那一块：选中后的"批注"钮，或正在写的那条批注（新的记下时才进草稿，回复框不在写的时候长高、把对话顶走）。
    enum Floating: Equatable {
        case offer(ReplyNote, at: Spot)
        case editing(ReplyNote, at: Spot, fresh: Bool)
    }

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                guard let id = ReplyNote.id(of: url) else { return .systemAction }
                if let note = services.settings.replyNotes(for: session).first(where: { $0.id == id }) {
                    float = .editing(note, at: Spot(point: watch.view?.pointer ?? .zero), fresh: false)
                }
                return .handled
            })
            .background { WatchView(watch: watch, changed: selectionChanged) }
            .overlay {
                if let float {
                    Anchored(spot: float.at, gap: Self.lineHalf + 4) { floating(float) }
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
            .animation(Motion.quick, value: float)
    }

    @ViewBuilder private func floating(_ float: Floating) -> some View {
        switch float {
        case .offer(let note, let at):
            Button { begin(note, at: at) } label: {
                Label("批注", icon: .said)
                    .font(Typography.caption.weight(.semibold))
                    .padding(.horizontal, 12).frame(height: 28)
                    .contentShape(.capsule)
            }
            .buttonStyle(PressStyle())
            .glass(in: .capsule, interactive: true, ink: .legible)
            .help("批注这段，随下一句发出")
        case .editing(let note, _, let fresh):
            NoteEditor(note: note) { text in
                if let text { save(note, text: text, fresh: fresh) } else if !fresh { remove(note) }
                self.float = nil
            }
        }
    }

    /// 半行高（阅读字号的字高加行距）：挂点在一行字中间。
    private static let lineHalf: CGFloat = {
        let font = NSFont.systemFont(ofSize: Typography.readingSize)
        return (font.ascender - font.descender + font.leading + Typography.readingLineSpacing) / 2
    }()

    /// 松开鼠标后的选区：落在某条回答里就在松手那一行下面浮出"批注"，否则收起；正在写批注时不动。
    /// 松手处常拖出了字外（行尾右边的空白、段落下面），挂点收回到那段字里最近的一行，浮层也不出这段字的左右。
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

    /// 选区所在的那条回答：交互视图的整段字就是某条回答的某一段可选文字（`MarkdownText.proseTexts`），从最新的往前认。
    private func note(for selection: SelectionWatch.Selection) -> ReplyNote? {
        for message in messages.reversed() where message.role == .known(.pi) {
            guard let run = prose.texts(of: message).firstIndex(of: selection.text) else { continue }
            let quote = (selection.text as NSString).substring(with: selection.range)
            return ReplyNote(entry: message.id, run: run, location: selection.range.location, quote: quote)
        }
        return nil
    }

    /// 同一处已经批注过就打开那一条，否则开始写新的一条。
    private func begin(_ note: ReplyNote, at: Spot) {
        let same = services.settings.replyNotes(for: session).first { $0.marksSamePlace(as: note) }
        float = .editing(same ?? note, at: at, fresh: same == nil)
    }

    /// 新的一条按在对话里的先后排进草稿；已有的那条改字（写的时候在回复框上删掉了就不再加回来）。
    private func save(_ note: ReplyNote, text: String, fresh: Bool) {
        var notes = services.settings.replyNotes(for: session), note = note
        note.note = text
        if fresh {
            notes = ReplyNote.sorted(notes + [note], by: messages.map(\.id))
        } else if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = note
        }
        services.settings.setReplyNotes(notes, for: session)
    }

    private func remove(_ note: ReplyNote) {
        services.settings.setReplyNotes(services.settings.replyNotes(for: session).filter { $0.id != note.id }, for: session)
    }
}

/// 浮层挂在哪：`point` 是某一行字的中间（对话区里的坐标），`columns` 是浮层左右不出的范围（那段字的左右边）。
private struct Spot: Equatable {
    var point: CGPoint
    var columns: ClosedRange<CGFloat> = -.infinity ... .infinity
}

private extension ReplyNoteLayer.Floating {
    var at: Spot {
        switch self {
        case .offer(_, let at), .editing(_, let at, _): at
        }
    }
}

/// 写一条批注：只有一行输入（原文已在对话里高亮着，不再重复）。批注一定要有字：↩ 或点别处记下；新的没写字时 ↩ 不收起、
/// 点别处就是不要；已有的那条清空后记下就删掉。esc 放弃这次的改动。字先留在这里、记下时才写进草稿：打字时对话里的高亮与回复框不跟着重算。
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
    private static let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(.said).font(Typography.secondary).foregroundStyle(palette.ink2).accessibilityHidden(true)
            TextField("写批注，↩ 挂到下一句", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Typography.secondary).foregroundStyle(palette.ink)
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit(submit)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(width: Self.width, alignment: .leading)
        .glass(in: Self.shape, ink: .solid)
        .onExitCommand { settle(note.note.isEmpty ? nil : note.note) }
        .onAppear { focused = true }
        .onChange(of: focused) { if !focused { commit() } }
    }

    /// 新的一条没写字时 ↩ 不收起：批注一定要写。
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

/// 把浮着的那一块挂在挂点那一行：默认在这一行下面（拖选多是从上往下，松手处是选区末尾，往下放不遮住选中的字），下面放不下就放到这一行上面；
/// 左右不出那段字，也不出对话区。按它自己的理想尺寸排，不读几何。
private struct Anchored: Layout {
    let spot: Spot

    /// 离挂点上下各让开这么多（`ReplyNoteLayer.lineHalf` 再多一点），不压住挂点那一行。
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

    func texts(of message: PiChatMessage) -> [String] {
        if let hit = texts[message.id], hit.source == message.text { return hit.prose }
        let prose = MarkdownText.proseTexts(message.text)
        texts[message.id] = (message.text, prose)
        return prose
    }
}

/// 批注层拿到它垫的那层视图（点高亮时读指针位置）。
private final class WatchHandle {
    weak var view: SelectionWatch?
}

/// 批注层每次重算都经这里把最新的回调交给 AppKit 那一侧。
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

/// 垫在对话区底下、与它同框的 AppKit 视图：所在窗口里松开鼠标时读一次这一下选的字，滚动或敲键时报"没有选区"（让浮着的钮让开）；
/// 也把窗口坐标换成对话区里的坐标。整页一个，平时不做事。
///
/// 读选区：SwiftUI 的可选文字（`textSelection`）在 Mac 上每个 `Text` 是一个交互视图，读屏接口（公开）给出它整段的字与选区，
/// 不经剪贴板、不碰私有类名。拖选时它不成为第一响应者，在别段选字时先前那段的选区也不清掉（macOS 26 实测），所以按下时记下各段的选区，
/// 松开后找这一下选区变了的那段。读屏接口给不出选区的位置（量出来是零），所以浮层挂在指针处。
/// 否决的：每条回答换成 TextKit 文本视图（长对话太重）、发"复制"去取（覆盖剪贴板）、每块挂悬停跟踪（`docs/ui.md`）。
private final class SelectionWatch: NSView {
    struct Selection {
        let text: String
        let range: NSRange
        let at: CGPoint
        /// 这段字在对话区里的框。
        let frame: CGRect
    }

    var changed: (Selection?) -> Void = { _ in }
    private var monitor: Any?
    /// 按下鼠标时各段的选区：松开时没变的不算这一下选的。
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

    /// 对话区里此刻选中的字：`counts` 认可的段里离窗口坐标 `point` 最近的那段；输入框（文本视图）里的不算。
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

    /// 对话区里的可选文字。
    private var texts: [NSView] {
        window?.contentView.map { Self.texts(in: $0, within: convert(bounds, to: nil)) } ?? []
    }

    /// 有读屏值（字）的视图，输入框除外；只往与对话区相交的子树里找。
    private static func texts(in view: NSView, within area: NSRect) -> [NSView] {
        guard view.convert(view.bounds, to: nil).intersects(area) else { return [] }
        let own: [NSView] = !(view is NSText) && view.accessibilityValue() is String ? [view] : []
        return own + view.subviews.flatMap { texts(in: $0, within: area) }
    }

    /// 指针此刻在对话区里的位置。
    var pointer: CGPoint { local(window?.mouseLocationOutsideOfEventStream ?? .zero) }

    private func local(_ point: NSPoint) -> CGPoint {
        let inside = convert(point, from: nil)
        return CGPoint(x: inside.x, y: isFlipped ? inside.y : bounds.height - inside.y)
    }
}
#endif
