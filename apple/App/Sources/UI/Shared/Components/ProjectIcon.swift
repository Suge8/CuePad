import CueStore
import SwiftUI

struct ProjectGlyph: View {
    let project: Project?
    var size: CGFloat = 13
    @Environment(\.palette) private var palette

    var body: some View {
        Image(Self.icon(project))
            .font(.system(size: size, weight: .medium))
            // 项目还没同步到时是墨色，不借系统灰或系统强调色（侧栏列表会把 Label 的图标染成强调蓝）
            .foregroundStyle(project.map { palette.project($0.color) } ?? palette.ink2)
            .frame(width: size + Self.margin)
            .readerHidden(true)
    }

    static let margin = Spacing.glyph

    static func icon(_ project: Project?) -> Icon { .project(ProjectIcon(stored: project?.icon)) }
}

/// 库里存的值不迁移：表外的名字认不出，是文件夹（含没存图标的）。
nonisolated enum ProjectIcon: String, CaseIterable, Sendable {
    // rawValue 就是库里已存的名字（早先表单存的系统符号名，更早版本存的 lucide 名 rocket）：已有项目直接认得，不用映射
    case folder, sparkles, chat = "bubble.left.and.bubble.right", terminal, globe, hammer, book, target
    case briefcase, cart, megaphone, paintbrush, lightbulb, flag, cube, leaf
    case layers, camera, house, heart, star, music = "music.note", rocket, bolt

    init(stored: String?) {
        self = stored.flatMap(Self.init(rawValue:)) ?? .folder
    }

    var name: LocalizedStringResource {
        switch self {
        case .folder: "文件夹"
        case .sparkles: "闪光"
        case .chat: "对话"
        case .terminal: "终端"
        case .globe: "地球"
        case .hammer: "锤子"
        case .book: "书"
        case .target: "靶心"
        case .briefcase: "公文包"
        case .cart: "购物车"
        case .megaphone: "喇叭"
        case .paintbrush: "画笔"
        case .lightbulb: "灯泡"
        case .flag: "旗帜"
        case .cube: "方块"
        case .leaf: "叶子"
        case .layers: "层"
        case .camera: "相机"
        case .house: "家"
        case .heart: "心"
        case .star: "星"
        case .music: "音符"
        case .rocket: "火箭"
        case .bolt: "闪电"
        }
    }
}
