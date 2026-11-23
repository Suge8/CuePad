import CueStore
import SwiftUI
import UniformTypeIdentifiers

/// 只在 App 里认的类型（`UTType.cuepadCard`）：拖成纯文字的话，路上的输入框（"添加任务"、回复框）把它当字接走、写进一串 id，别的 App 也会收到它。
nonisolated enum DraggedCard: Hashable, Codable, Sendable, Transferable {
    case task(UUID), idea(UUID), session(String)

    var task: UUID? { if case .task(let id) = self { id } else { nil } }
    var idea: UUID? { if case .idea(let id) = self { id } else { nil } }
    var session: String? { if case .session(let id) = self { id } else { nil } }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .cuepadCard)
    }
}

nonisolated struct DraggedTaskSession: Transferable {
    let card: DraggedCard
    let session: DraggedSession
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.session)
        ProxyRepresentation(exporting: \.card)
    }
}

extension UTType {
    nonisolated static let cuepadCard = UTType(exportedAs: "\(AppIdentity.id).card")
}

/// 落点的亮起只读它：只靠落点自己的"拖进来了"，拖到别处放下或取消时它收不到"拖走了"，底与线会一直留着（手机上像卡片之间插了一条横向滑动条）。开始与结束由拖的那一头报，放在哪、取消都一定收得到。
/// 引用放进环境、只建一次：拖起与放下只重算读它的落点，不重算墙上每一张能拖的卡。
@Observable
final class CardDrags {
    fileprivate(set) var current: DraggedCard?
}

extension EnvironmentValues {
    @Entry var cardDrags: CardDrags?
}

extension View {
    func cardDragStage() -> some View { modifier(CardDragStage()) }

    /// 不给 `shape` 时预览是直角矩形，圆角的卡与行四角露出直角的底。
    /// `chip`：没有底的行（任务行、"更早"的行）给它的标题。手机拖起时系统把整行缩小、垫一块直角的白底，改拖一张写着标题的小纸（`DragChip`）；
    /// 自己有纸的卡不给，拖的就是它自己。Mac 拖的是行原样的影子，不用。
    func cardDraggable(_ card: DraggedCard, session: String? = nil, chip: String? = nil, shape: some Shape) -> some View {
        modifier(CardDraggable(card: card, session: session, chip: chip, shape: shape))
    }

    func cardDrop(isEnabled: Bool = true, hover: @escaping (CGPoint?) -> Void = { _ in }, perform: @escaping (DraggedCard, CGPoint) -> Void) -> some View {
        modifier(CardDrop(isEnabled: isEnabled, hover: hover, perform: perform))
    }
}

private struct CardDragStage: ViewModifier {
    @State private var drags = CardDrags()

    func body(content: Content) -> some View {
        content.environment(\.cardDrags, drags)
    }
}

private struct CardDrop: ViewModifier {
    let isEnabled: Bool
    let hover: (CGPoint?) -> Void
    let perform: (DraggedCard, CGPoint) -> Void
    @Environment(\.cardDrags) private var drags
    @Environment(\.pageActive) private var active

    // 挂着不看的页（Mac 的 `PageStack`）不认任何类型：透明、点不到的页上的落点照样接拖放，叠在当前页的落点上把拖进来的抢走
    func body(content: Content) -> some View {
        content.onDrop(of: active ? [.cuepadCard] : [], delegate: Delegate(drop: self, drags: drags))
    }

    private struct Delegate: DropDelegate {
        let drop: CardDrop
        let drags: CardDrags?

        func validateDrop(info: DropInfo) -> Bool { drop.isEnabled && drags?.current != nil }
        func dropEntered(info: DropInfo) { drop.hover(info.location) }
        func dropUpdated(info: DropInfo) -> DropProposal? {
            drop.hover(info.location)
            return DropProposal(operation: .move)
        }
        func dropExited(info: DropInfo) { drop.hover(nil) }
        func performDrop(info: DropInfo) -> Bool {
            defer { drop.hover(nil) }
            guard let card = drags?.current else { return false }
            drop.perform(card, info.location)
            return true
        }
    }
}

private struct CardDraggable<S: Shape>: ViewModifier {
    let card: DraggedCard
    let session: String?
    let chip: String?
    let shape: S
    @Environment(\.cardDrags) private var drags
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    private var wide: WideNavigation.Pane?? {
        if let session = session ?? card.session { return .session(SessionRoute(id: SessionState.recordID(sessionID: session), sessionID: session)) }
        return .some(card.idea.map { .card($0) })
    }

    func body(content: Content) -> some View {
        Group {
            if let session, workspace.layout == .wide {
                content.draggable(DraggedTaskSession(card: card, session: DraggedSession(sessionID: session)))
            } else {
                #if os(iOS)
                if let chip {
                    content.draggable(card) { DragChip(title: chip, task: card.task != nil, palette: palette) }
                } else {
                    content.draggable(card)
                }
                #else
                content.draggable(card)
                #endif
            }
        }
            .contentShape(.dragPreview, shape)
            .reportsWideDrag(wide)
            .onDragSessionUpdated { session in
                guard let drags else { return }
                switch session.phase {
                case .initial, .active: if drags.current != card { drags.current = card }
                default: if drags.current == card { drags.current = nil }
                }
            }
    }
}

#if os(iOS)
/// 拖起的那张小纸。预览画在系统的拖放层里、读不到 App 的环境，颜色由拖起的那一行带进来。
private struct DragChip: View {
    let title: String
    let task: Bool
    let palette: Palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card)
        HStack(spacing: Spacing.item) {
            Image(task ? .task : .idea).foregroundStyle(palette.ink3)
            Text(title).font(Typography.body.weight(.medium)).foregroundStyle(palette.ink).lineLimit(1)
        }
        .padding(.horizontal, Spacing.block).padding(.vertical, Spacing.item)
        .frame(maxWidth: Self.width, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        .background(palette.paper, in: shape)
        .contentShape(.dragPreview, shape)
    }

    private static let width: CGFloat = 260
}
#endif
