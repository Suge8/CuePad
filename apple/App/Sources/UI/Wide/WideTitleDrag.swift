#if os(iOS)
import SwiftUI

struct WideTitleDrag: UIViewRepresentable {
    let title: String
    let item: DraggedColumn
    @Environment(Workspace.self) private var workspace

    func makeUIView(context: Context) -> WideTitleLabel {
        WideTitleLabel(item: item, workspace: workspace)
    }

    func updateUIView(_ view: WideTitleLabel, context: Context) {
        view.text = title
        view.item = item
    }
}

final class WideTitleLabel: UILabel, UIDragInteractionDelegate {
    var item: DraggedColumn
    private let workspace: Workspace

    init(item: DraggedColumn, workspace: Workspace) {
        self.item = item
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
}
#endif
