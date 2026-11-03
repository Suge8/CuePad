import SwiftUI

/// 栏头的标题位，宽屏两栏同一套：会话栏写会话名（`WideSessionTitle`），主栏开着项目页时写项目名（`WideProjectHeading`）。
/// 一行标题；`detail` 不为 nil 时下面一行小字（空串也占着这一行：项目有没有写介绍，栏头的字都不上下跳）。
struct WideHeading: View {
    let title: String
    var detail: String?
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: title).font(.headline).foregroundStyle(palette.ink).lineLimit(1)
            if let detail {
                Text(verbatim: detail.isEmpty ? " " : detail).font(Typography.caption).foregroundStyle(palette.ink3).lineLimit(1)
                    .help(detail)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// 主栏开着项目页时栏头的项目名，第二行是项目的一句介绍（`Project.intro`）。读内存里的项目目录（`Workspace.catalog`），不另订阅；
/// 文件夹与"规则"留在页里那一行（`ProjectIntroLine` 的 `intro: false`）。书架与进展页不写；Mac 编辑浮层开着时不写（浮层自己写是哪一份，`OverlayTitle`）。
struct WideProjectHeading: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if !overlaid, case .project(let id) = workspace.mainRoute, let project = workspace.catalog?.project(id) {
            WideHeading(title: project.shownName, detail: project.intro ?? "")
        }
    }

    private var overlaid: Bool {
        #if os(macOS)
        workspace.overlay != nil
        #else
        false
        #endif
    }
}
