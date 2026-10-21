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
/// Mac 上还没交出去的叶子的"▶ 开始"悬停时浮在行尾（`TaskLine` 的 `hoverReveal`），盖住这一格，不占排版。
struct BoardRowEnd<Extra: View>: View {
    let project: Project?
    @ViewBuilder var extra: Extra

    var body: some View {
        HStack(spacing: TaskLineLayout.gap) {
            extra
            if let project { ProjectGlyph(project: project, size: Self.glyph).help(project.name) }
        }
        .fixedSize()
    }

    #if os(macOS)
    private static var glyph: CGFloat { 10 }
    #else
    private static var glyph: CGFloat { 12 }
    #endif
}

extension BoardRowEnd where Extra == EmptyView {
    init(project: Project?) {
        self.init(project: project) { EmptyView() }
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
