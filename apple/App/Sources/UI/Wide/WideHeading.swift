import SwiftUI

/// 宽屏主区栏头的标题位：项目页写项目名与介绍（`WideProjectHeading`），项目列表、归档、回收站写页名；会话的栏头另是「项目 / 会话名」（`WideSessionTitle`）。
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

extension View {
    /// 宽屏栏头里空着的那截按住拖窗口（Mac；栏头在标题栏那一排，主区与 Cue 的托管视图不让标题栏自己拖，`ColumnHostingView`）。
    /// 挂在栏头那一排的底上：钮在上面照常点，钮之间的空处接拖动；双击同标题栏（缩放窗口）。iOS 上什么都不做。
    @ViewBuilder func windowDragArea() -> some View {
        #if os(macOS)
        background { Color.clear.contentShape(.rect).gesture(WindowDragGesture()).allowsWindowActivationEvents(true) }
        #else
        self
        #endif
    }
}
