import SwiftUI

/// 胶囊名字的把手：盖在名字上的一层平台视图，按住拖出去由它起系统拖放（落点见 `WideDrop`）。SwiftUI 的 `.draggable` 两端都不够用：
/// Mac 上拖不到别的块（见 `PaneGripView`），拎起的样子两端都换不成 `PaneChip`。
struct PaneGrip {
    let title: String
    let column: DraggedColumn
    let pane: WideNavigation.Pane
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    typealias Lift = @MainActor (CGFloat) -> (data: Data, chip: ImageRenderer<PaneChip>)?

    private var lift: Lift {
        { [workspace, column, title, palette] scale in
            do {
                let chip = ImageRenderer(content: PaneChip(title: title, palette: palette))
                chip.scale = scale
                return (try JSONEncoder().encode(column), chip)
            } catch {
                workspace.fail(error)
                return nil
            }
        }
    }
}

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
extension PaneGrip: UIViewRepresentable {
    func makeUIView(context: Context) -> PaneGripView { PaneGripView() }

    func updateUIView(_ view: PaneGripView, context: Context) {
        view.lift = lift
        view.dragging = { [workspace, pane] on in workspace.dragging = on ? .some(pane) : nil }
    }
}

final class PaneGripView: UIView, UIDragInteractionDelegate {
    var lift: PaneGrip.Lift?
    /// 拖着时落点读不到带的东西（`UIDropSession` 放下才给），起拖时把拖的是哪一块记给 `Workspace.dragging`。
    var dragging: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        addInteraction(UIDragInteraction(delegate: self))
    }

    required init?(coder: NSCoder) { nil }

    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] {
        guard let lifted = lift?(traitCollection.displayScale) else { return [] }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: DraggedColumn.type.identifier, visibility: .all) { [data = lifted.data] completion in
            completion(data, nil)
            return nil
        }
        let item = UIDragItem(itemProvider: provider)
        item.localObject = lifted.chip.uiImage
        return [item]
    }

    func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: any UIDragSession) -> UITargetedDragPreview? {
        guard let window, let image = item.localObject as? UIImage else { return nil }
        let chip = UIImageView(image: image)
        let parameters = UIDragPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(roundedRect: chip.bounds, cornerRadius: chip.bounds.height / 2)
        let center = convert(CGPoint(x: chip.bounds.width / 2 - Spacing.block, y: bounds.midY), to: window)
        return UITargetedDragPreview(view: chip, parameters: parameters, target: UIDragPreviewTarget(container: window, center: center))
    }

    func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: any UIDragSession) { dragging?(true) }
    func dragInteraction(_ interaction: UIDragInteraction, session: any UIDragSession, didEndWith operation: UIDropOperation) { dragging?(false) }
}
#else
import AppKit

extension PaneGrip: NSViewRepresentable {
    func makeNSView(context: Context) -> PaneGripView { PaneGripView() }
    func updateNSView(_ view: PaneGripView, context: Context) { view.lift = lift }
}

final class PaneGripView: NSView, NSDraggingSource {
    var lift: PaneGrip.Lift?
    private var pressed: NSEvent?
    private static let slop: CGFloat = 3

    init() {
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { nil }

    // 胶囊在标题栏那一排，系统把那里的按住拖当成拖窗口，不看按下落在谁身上：名字用 `.draggable` 时拖放起来了、窗口却跟着指针走，
    // 指针相对窗口不动，拖不到别的块上；这层视图答了"不能"、按下也收到了，窗口照样走（macOS 27 实测）。
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
        let chip = lifted.chip.nsImage
        let size = chip?.size ?? bounds.size
        item.setDraggingFrame(NSRect(x: -Spacing.block, y: (bounds.height - size.height) / 2, width: size.width, height: size.height), contents: chip)
        beginDraggingSession(with: [item], event: pressed, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }
}
#endif
