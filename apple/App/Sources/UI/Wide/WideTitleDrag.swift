import SwiftUI

/// 按住名字拖出去时拎在手上的那一颗：写着名字的小胶囊。系统默认拎起的是名字那几个字的截图，Mac 上没有底、iPad 上是一块白条（iPadOS 27 模拟器实测）。
struct PaneChip: View {
    let title: String
    let palette: Palette

    var body: some View {
        Text(verbatim: title).font(Typography.toolbarTitle).foregroundStyle(palette.ink).lineLimit(1)
            .padding(.horizontal, Spacing.block)
            .frame(height: Chrome.control)
            .frame(maxWidth: 320)
            .fixedSize()
            .background(palette.paper, in: .capsule)
            .overlay { Capsule().strokeBorder(palette.hair) }
    }
}

#if os(iOS)
struct WideTitleDrag: UIViewRepresentable {
    let title: String
    let column: DraggedColumn
    let pane: WideNavigation.Pane
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    func makeUIView(context: Context) -> WideTitleLabel {
        WideTitleLabel(column: column, pane: pane, palette: palette, workspace: workspace)
    }

    func updateUIView(_ view: WideTitleLabel, context: Context) {
        view.text = title
        view.column = column
        view.pane = pane
        view.palette = palette
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: WideTitleLabel, context: Context) -> CGSize? {
        let ideal = view.intrinsicContentSize
        return CGSize(width: min(ideal.width, proposal.width ?? ideal.width), height: ideal.height)
    }
}

final class WideTitleLabel: UILabel, UIDragInteractionDelegate {
    var column: DraggedColumn
    var pane: WideNavigation.Pane
    var palette: Palette
    private let workspace: Workspace

    init(column: DraggedColumn, pane: WideNavigation.Pane, palette: Palette, workspace: Workspace) {
        self.column = column
        self.pane = pane
        self.palette = palette
        self.workspace = workspace
        super.init(frame: .zero)
        font = .preferredFont(forTextStyle: .headline)
        adjustsFontForContentSizeCategory = true
        lineBreakMode = .byTruncatingTail
        isUserInteractionEnabled = true
        accessibilityTraits = [.staticText, .header]
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addInteraction(UIDragInteraction(delegate: self))
    }

    required init?(coder: NSCoder) { nil }

    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] {
        do {
            let data = try JSONEncoder().encode(column)
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: DraggedColumn.type.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
            return [UIDragItem(itemProvider: provider)]
        } catch {
            workspace.fail(error)
            return []
        }
    }

    func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: any UIDragSession) -> UITargetedDragPreview? {
        let renderer = ImageRenderer(content: PaneChip(title: text ?? "", palette: palette))
        renderer.scale = traitCollection.displayScale
        guard let window, let image = renderer.uiImage else { return nil }
        let chip = UIImageView(image: image)
        let parameters = UIDragPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(roundedRect: chip.bounds, cornerRadius: chip.bounds.height / 2)
        let center = convert(CGPoint(x: chip.bounds.width / 2 - Spacing.block, y: bounds.midY), to: window)
        return UITargetedDragPreview(view: chip, parameters: parameters, target: UIDragPreviewTarget(container: window, center: center))
    }

    func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: any UIDragSession) { workspace.dragging = .some(pane) }
    func dragInteraction(_ interaction: UIDragInteraction, session: any UIDragSession, didEndWith operation: UIDropOperation) { workspace.dragging = nil }
}
#else
import AppKit

/// Mac 上胶囊名字的把手：盖在名字上的一层 AppKit 视图。胶囊在标题栏那一排，系统把那里的按住拖当成拖窗口：名字用 `.draggable` 时拖放起来了、
/// 窗口却跟着指针走，指针相对窗口不动，拖不到别的块上（macOS 27 实测）。这一层在指针停上来时让窗口先不可移动（`PaneGripView`），
/// 按住拖出去由它起系统拖放，拎起的是 `PaneChip`。
struct PaneGrip: NSViewRepresentable {
    let title: String
    let column: DraggedColumn
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    func makeNSView(context: Context) -> PaneGripView { PaneGripView() }

    func updateNSView(_ view: PaneGripView, context: Context) {
        view.lift = { [workspace, column, title, palette] scale in
            do {
                let renderer = ImageRenderer(content: PaneChip(title: title, palette: palette))
                renderer.scale = scale
                return (try JSONEncoder().encode(column), renderer.nsImage)
            } catch {
                workspace.fail(error)
                return nil
            }
        }
    }
}

final class PaneGripView: NSView, NSDraggingSource {
    var lift: ((CGFloat) -> (data: Data, chip: NSImage?)?)?
    private var pressed: NSEvent?
    private static let slop: CGFloat = 3

    init() {
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { nil }

    // 标题栏那一排的拖窗口不看按下落在谁身上：这层视图答了"不能"、按下也收到了，窗口照样跟着走（胶囊的玻璃底答"能"，它的范围整块算可拖）。
    // 只有窗口整个不可移动才拦得住，按下那一刻再改已经晚了，所以指针停在名字上时就先关掉、离开时放回。
    override func mouseEntered(with event: NSEvent) { window?.isMovable = false }
    override func mouseExited(with event: NSEvent) { window?.isMovable = true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { window?.isMovable = true }
        super.viewWillMove(toWindow: newWindow)
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressed = event }
    override func mouseUp(with event: NSEvent) { pressed = nil }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed, hypot(event.locationInWindow.x - pressed.locationInWindow.x, event.locationInWindow.y - pressed.locationInWindow.y) > Self.slop else { return }
        self.pressed = nil
        guard let lifted = lift?(window?.backingScaleFactor ?? 2) else { return }
        let board = NSPasteboardItem()
        board.setData(lifted.data, forType: .init(DraggedColumn.type.identifier))
        let item = NSDraggingItem(pasteboardWriter: board)
        let size = lifted.chip?.size ?? bounds.size
        item.setDraggingFrame(NSRect(x: -Spacing.block, y: (bounds.height - size.height) / 2, width: size.width, height: size.height), contents: lifted.chip)
        beginDraggingSession(with: [item], event: pressed, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }
}
#endif
