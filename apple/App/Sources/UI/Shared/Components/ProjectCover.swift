import CueStore
import SwiftUI

/// 项目的封面：Cue 去的十二个地方（`Assets.xcassets/ProjectCovers`，3:1 的横幅），像素画。项目列表里它那张卡与项目页顶上是同一张。
/// 画成像素的、不画成同 Cue 本体一样的软陶：Cue 那一栏已经是一幅立体的画，主区再来一幅，两幅并排着抢。
/// 由图标固定映射（两个图标一幅），改名、计数或时间变化都不换图。
nonisolated enum ProjectCover: String, Sendable {
    case whale, shark, jellyfish, turtle, fox, cat, penguin, owl, monstera, cactus, mushroom, flower

    init(_ icon: ProjectIcon) {
        self = switch icon {
        case .chat, .music: .whale
        case .rocket, .hammer: .shark
        case .layers, .cube: .jellyfish
        case .globe, .flag: .turtle
        case .target, .bolt: .fox
        case .house, .heart: .cat
        case .camera, .megaphone: .penguin
        case .book, .lightbulb: .owl
        case .leaf, .paintbrush: .monstera
        case .cart, .terminal: .cactus
        case .folder, .briefcase: .mushroom
        case .sparkles, .star: .flower
        }
    }

    /// 画里 Cue 与它身边那一样东西的中心：框比画窄或扁时围着它裁，不把主角裁到框外。
    fileprivate var focus: UnitPoint {
        switch self {
        case .whale: UnitPoint(x: 0.6, y: 0.52)
        case .shark: UnitPoint(x: 0.62, y: 0.5)
        case .jellyfish: UnitPoint(x: 0.56, y: 0.5)
        case .turtle: UnitPoint(x: 0.62, y: 0.58)
        case .fox: UnitPoint(x: 0.48, y: 0.7)
        case .cat: UnitPoint(x: 0.6, y: 0.72)
        case .penguin: UnitPoint(x: 0.55, y: 0.55)
        case .owl: UnitPoint(x: 0.6, y: 0.45)
        case .monstera: UnitPoint(x: 0.55, y: 0.55)
        case .cactus: UnitPoint(x: 0.6, y: 0.58)
        case .mushroom: UnitPoint(x: 0.52, y: 0.55)
        case .flower: UnitPoint(x: 0.6, y: 0.58)
        }
    }

    fileprivate static let aspect: CGFloat = 3
}

/// 铺满给它的那一块，多出来的围着画的主角裁掉。
struct ProjectCoverImage: View {
    let cover: ProjectCover
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var scale
    /// 图的宽（像素），十二张相差不到一成。
    private static let pixels: CGFloat = 1360

    init(_ project: Project) { cover = ProjectCover(ProjectIcon(stored: project.icon)) }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size, height = max(size.height, size.width / ProjectCover.aspect), width = height * ProjectCover.aspect
            // 图里一格是 8×8 的整块（格子按原画的格线取色，不是整张缩小：缩小会把相邻两格掺成灰）。
            // 画得比图大时不插值，一格还是一个方块；画得比图小（项目卡、手机）时照常缩小，不插值的话抖色会起纹
            Image(decorative: "cover-\(cover.rawValue)").resizable().interpolation(width * scale >= Self.pixels ? .none : .high)
                .frame(width: width, height: height)
                .offset(x: min(max(size.width / 2 - width * cover.focus.x, size.width - width), 0),
                        y: min(max(size.height / 2 - height * cover.focus.y, size.height - height), 0))
        }
        // 深色下白天的画压暗一点：整窗是暗的，一块亮天空刺眼
        .brightness(scheme == .dark ? -0.1 : 0)
        .accessibilityHidden(true) // 合并项目卡内排除装饰，另包容器会把封面挡在合并之外。
        .allowsHitTesting(false)
    }
}

/// 项目页最上面的通栏：每个项目进来是它自己的地方，不是同一页换了几行字。
/// 是内容的第一块、跟着滚走，不钉在顶上：栏头不随滚动位置变（会形成布局循环，见 `ProjectPage`）。
struct ProjectBanner: View {
    let project: Project

    var body: some View {
        // 高跟着宽长，窄到手机不矮过 150、宽到大屏不高过 260：再高首屏就只剩画了
        Color.clear.aspectRatio(4.2, contentMode: .fit).frame(minHeight: 150, maxHeight: 260)
            .frame(maxWidth: .infinity)
            .overlay { ProjectCoverImage(project) }
            .clipShape(.rect(cornerRadius: Radius.card))
    }
}
