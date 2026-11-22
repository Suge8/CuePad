#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

struct WideTitleDrag: UIViewRepresentable {
    let title: String
    let type: UTType
    let item: any Encodable & Sendable
    let pane: WideNavigation.Beside
    @Environment(Workspace.self) private var workspace

    func makeUIView(context: Context) -> WideTitleLabel {
        WideTitleLabel(type: type, item: item, pane: pane, workspace: workspace)
    }

    func updateUIView(_ view: WideTitleLabel, context: Context) {
        view.text = title
        view.type = type
        view.item = item
        view.pane = pane
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: WideTitleLabel, context: Context) -> CGSize? {
        let ideal = view.intrinsicContentSize
        return CGSize(width: min(ideal.width, proposal.width ?? ideal.width), height: ideal.height)
    }
}

final class WideTitleLabel: UILabel, UIDragInteractionDelegate {
    var type: UTType
    var item: any Encodable & Sendable
    var pane: WideNavigation.Beside
    private let workspace: Workspace

    init(type: UTType, item: any Encodable & Sendable, pane: WideNavigation.Beside, workspace: Workspace) {
        self.type = type
        self.item = item
        self.pane = pane
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
            let data = try JSONEncoder().encode(item)
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
            return [UIDragItem(itemProvider: provider)]
        } catch {
            workspace.fail(error)
            return []
        }
    }

    func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: any UIDragSession) { workspace.dragging = .some(pane) }
    func dragInteraction(_ interaction: UIDragInteraction, session: any UIDragSession, didEndWith operation: UIDropOperation) { workspace.dragging = nil }
}
#endif
