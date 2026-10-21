import CueStore
import SwiftUI

/// 任务看板上的行比别处多的（`BoardColumn` 给 `TaskLine`）。
struct BoardLook {
    /// 行尾的项目小图标：看全部项目时才有（选了项目范围时范围已经说了，不画）。
    var project: Project?
    /// 已完成的：Cue 做完时点名的成果图（`TaskBoard.Item.shot`）与点开它（全屏预览，底栏对 Cue 说）。
    var shot: CueShown?
    var openShot: (PreviewOpening) -> Void = { _ in }
    /// 在推进中：整行点了进此刻干活的会话，歇着的标题淡一档（`BoardPulse`）。
    var advancing = false

    /// 行尾有东西要画。
    var hasEnd: Bool { project != nil || shot != nil }
}

/// 看板行尾的最后一格（任务行与推进中的会话行同一种）：前面可放成果图，末尾是项目小图标（项目色只上图形）。
/// Mac 上还没交出去的叶子的"▶ 开始"与项目小图标叠在同一格：悬停时图标让位、"开始"在留好的位置露出来，标题不被挤动。
struct BoardRowEnd<Extra: View>: View {
    let project: Project?
    /// "开始"（`TaskNext.start`）；不是能开始的叶子为 nil。
    var start: TaskNext?
    @ViewBuilder var extra: Extra
    @Environment(\.rowHovered) private var lit

    var body: some View {
        HStack(spacing: TaskLineLayout.gap) {
            extra
            #if os(macOS)
            ZStack(alignment: .trailing) {
                if let project { glyph(project).opacity(start != nil && lit ? 0 : 1) }
                if let start { TaskNextMark(next: start) }
            }
            .animation(Motion.quick, value: lit)
            #else
            if let start { TaskNextMark(next: start) }
            if let project { glyph(project) }
            #endif
        }
        .fixedSize()
    }

    private func glyph(_ project: Project) -> some View { ProjectGlyph(project: project, size: Self.glyph).help(project.name) }

    #if os(macOS)
    private static var glyph: CGFloat { 10 }
    #else
    private static var glyph: CGFloat { 12 }
    #endif
}

extension BoardRowEnd where Extra == EmptyView {
    init(project: Project?) {
        self.init(project: project, start: nil) { EmptyView() }
    }
}

/// 已完成行尾的成果图：一张小缩略图（同一种交付物缩略图 `DeliverableTile`），点开全屏看（`previewPresenter`）。
struct BoardShot: View {
    let shot: CueShown
    let group: String
    let open: (PreviewOpening) -> Void

    var body: some View {
        DeliverableTile(
            preview: shot.preview, label: shot.look, shape: .strip(height: Self.height), captioned: false, zoom: PreviewZoomKey(group: group, preview: shot.id)
        ) { _ in open(Self.opening(shot, group: group)) }
        // 竖着居中在标题的字上：标的中线在基线以上约 0.36 个字高
        .alignmentGuide(.firstTextBaseline) { $0.height / 2 + Self.midline }
    }

    /// 点开它：全屏只这一张，页顶写看什么，底栏对 Cue 说（同结果卡）。
    static func opening(_ shot: CueShown, group: String) -> PreviewOpening {
        PreviewOpening(preview: shot.preview, batch: [shot.preview], group: group, reply: .cue, looks: [shot.id: shot.look])
    }

    #if os(macOS)
    private static let height: CGFloat = 18
    private nonisolated static let midline: CGFloat = 5
    #else
    private static let height: CGFloat = 26
    private nonisolated static let midline: CGFloat = 6
    #endif
}
