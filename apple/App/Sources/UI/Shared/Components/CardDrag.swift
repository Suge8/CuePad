import CueStore
import SwiftUI
import UniformTypeIdentifiers

/// 拖着的一条灵感或任务：项目页的墙与"更早"拖灵感，任务大纲与看板拖任务。
/// 只在 App 里认的类型（`UTType.cuepadCard`）：拖成纯文字时，路上的输入框（"添加任务"、回复框）把它当字接走、写进一串 id，别的 App 也会收到它。
nonisolated enum DraggedCard: Hashable, Codable, Sendable, Transferable {
    case task(UUID), idea(UUID)

    var task: UUID? { if case .task(let id) = self { id } else { nil } }
    var idea: UUID? { if case .idea(let id) = self { id } else { nil } }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .cuepadCard)
    }
}

extension UTType {
    /// 两端 Info.plist 导出的同一个标识（`$(CUEPAD_APP_ID).card`）。
    nonisolated static let cuepadCard = UTType(exportedAs: "\(AppIdentity.id).card")
}

/// 一页上此刻拖着的那一条（`cardDragStage` 建、`cardDraggable` 写）。落点的亮起只读它：只靠落点自己的"拖进来了"，
/// 拖到别处放下或取消时它收不到"拖走了"，底与线会一直留着（手机上像卡片之间插了一条横向滑动条）。开始与结束由拖的那一头报，放在哪、取消都一定收得到。
/// 引用放进环境、只建一次：拖起与放下只重算读它的落点，不重算墙上每一张能拖的卡。
@Observable
final class CardDrags {
    fileprivate(set) var current: DraggedCard?
}

extension EnvironmentValues {
    @Entry var cardDrags: CardDrags?
}

extension View {
    /// 一页能拖卡的范围（项目页、看板）：同页的落点都认这一份。
    func cardDragStage() -> some View { modifier(CardDragStage()) }

    /// 能拖的一条。`shape` 是拖起来那张预览的轮廓：不给时预览是直角矩形，圆角的卡与行四角露出直角的底。
    func cardDraggable(_ card: DraggedCard, shape: some Shape) -> some View {
        modifier(CardDraggable(card: card, shape: shape))
    }

    /// 只收这一页拖着的卡的落点（`CardDrags` 记着是哪条；别的页、别的 App 拖来的不收）。`hover` 报指针在落点里的位置（落点自己的坐标系），
    /// 拖走与放下后报 nil；`perform` 收放下的那一条与松手的位置，先于放下后的那个 nil：落点的状态（拖进来时的起点）放下时还在。
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
    let shape: S
    @Environment(\.cardDrags) private var drags

    func body(content: Content) -> some View {
        content
            .contentShape(.dragPreview, shape)
            .draggable(card)
            .onDragSessionUpdated { session in
                guard let drags else { return }
                switch session.phase {
                case .initial, .active: if drags.current != card { drags.current = card }
                default: if drags.current == card { drags.current = nil }
                }
            }
    }
}
