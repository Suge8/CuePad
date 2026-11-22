import CueStore
import SwiftUI

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

struct ProjectCoverImage: View {
    let cover: ProjectCover
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var scale
    private static let pixels: CGFloat = 1360

    init(_ project: Project) { cover = ProjectCover(ProjectIcon(stored: project.icon)) }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size, height = max(size.height, size.width / ProjectCover.aspect), width = height * ProjectCover.aspect
            Image(decorative: "cover-\(cover.rawValue)").resizable().interpolation(width * scale >= Self.pixels ? .none : .high)
                .frame(width: width, height: height)
                .offset(x: min(max(size.width / 2 - width * cover.focus.x, size.width - width), 0),
                        y: min(max(size.height / 2 - height * cover.focus.y, size.height - height), 0))
        }
        .brightness(scheme == .dark ? -0.1 : 0)
        .accessibilityHidden(true) // 合并项目卡内排除装饰，另包容器会把封面挡在合并之外。
        .allowsHitTesting(false)
    }
}

struct ProjectBanner: View {
    let project: Project

    var body: some View {
        Color.clear.aspectRatio(4.2, contentMode: .fit).frame(minHeight: 150, maxHeight: 260)
            .frame(maxWidth: .infinity)
            .overlay { ProjectCoverImage(project) }
            .clipShape(.rect(cornerRadius: Radius.card))
    }
}
