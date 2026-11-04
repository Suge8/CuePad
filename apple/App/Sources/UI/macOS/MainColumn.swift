#if os(macOS)
import CueStore
import SwiftUI

/// 主区（并排时是左半）：挂着的页（`PageStack`）、盖在上面的编辑页与文件页，栏头在窗口最顶那一排。
/// 栏头只说这一页是什么、放这一页的操作："⋯"（`PageMenuSlot`）在右端，同步提醒在它左边。浏览页与辅助页的栏头由这里画：
/// 项目页是项目名与介绍（`WideProjectHeading`），项目列表、归档、回收站写页名，技能与规则是规则｜技能与说明，编辑浮层是收起与是哪一份（`OverlayTitle`）。
/// 进展页没有另一排：看板四列的列头就是这一排（`TaskBoardPage`），右端只有"⋯"（项目范围收在里面）。会话页的栏头是页自己画的（`WideSessionTitle`）。
/// 页从这一排下面开始、内容滚到它后面（`PageStack` 按页让出 `Chrome.band`）；搜索在会话条顶上，项目｜进展在会话条里，栏头不放导航。
struct MainColumn: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.headInset) private var inset

    private var session: Bool { if case .session = workspace.mainRoute, workspace.overlay == nil { true } else { false } }

    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                PageStack()
                Group {
                    EditorLayer()
                    LibraryFileLayer()
                }
                .safeAreaPadding(.top, Chrome.band)
                .zIndex(1)
            }
            .overlay(alignment: .bottom) { CaptureSlot() }
            if !session { head }
        }
        .environment(\.topBand, Chrome.band)
        .ignoresSafeArea(.container, edges: .top)
    }

    /// 进展页那一排是看板的列头：栏头只占右端那几颗钮，不盖住列头（空处拖窗口由看板自己接，`TaskBoardPage`）；别的页栏头铺满这一排，空处接拖窗口。
    @ViewBuilder private var head: some View {
        if workspace.mainRoute == .progress, workspace.overlay == nil {
            MainHead().padding(inset).frame(maxWidth: .infinity, alignment: .trailing).frame(height: Chrome.band)
        } else {
            MainHead().padding(inset).frame(height: Chrome.band).windowDragArea()
        }
    }
}

/// 并排时主区的右半：⌘ 点开的第二个会话（`Workspace.besideSession`），栏头是它自己的（`WideSessionTitle`）。
struct BesideColumn: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Group {
            if let id = workspace.besideSession?.sessionID { SessionPage(sessionID: id, column: .beside).id(id) }
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// 主区的栏头（不是会话页时）：左边这一页是什么，右边同步提醒与"⋯"。
private struct MainHead: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    var body: some View {
        HStack(spacing: 0) {
            if workspace.overlay != nil {
                CloseButton()
                OverlayTitle()
            } else {
                page
            }
            Spacer(minLength: Spacing.item)
            // 看板那一排是列头，不给提醒常驻一格（列头少让一截）；要关注时才露
            if workspace.mainRoute != .progress || SyncAlertSlot.needed(services) { SyncAlertSlot() }
            if workspace.mainRoute == .library, workspace.overlay == nil { LibraryHelpSlot() }
            PageMenuSlot()
        }
    }

    @ViewBuilder private var page: some View {
        switch workspace.mainRoute {
        case .project: WideProjectHeading()
        case .shelf: WideHeading(title: String(localized: "项目"))
        case .archive: WideHeading(title: String(localized: "归档"))
        case .trash: WideHeading(title: String(localized: "回收站"))
        case .library: LibraryPanesSlot()
        default: EmptyView()
        }
    }
}

extension EnvironmentValues {
    /// 页顶那一排（窗口最顶那一排）的高：排进那一排的东西（项目页下滚后的回到顶部）按它定高、居中，与栏头的控件同一条中线。
    @Entry var topBand: CGFloat = 0
}
#endif
