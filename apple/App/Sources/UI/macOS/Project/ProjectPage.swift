#if os(macOS)
import CueStore
import SwiftUI

struct ProjectPage: View {
    let projectID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pageActive) private var active
    @State private var data: ProjectPageData?
    @State private var board = WallBoard()
    @State private var position = ScrollPosition()
    @State private var anchor = TaskFoldAnchor()
    @State private var stage = Stage.header

    private enum Stage: Int, CaseIterable, Comparable {
        case header, focus, wall, older
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    private static let bottomClearance: CGFloat = 88

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { content }
                .scrollPosition($position)
                .underGlass()
                .taskFoldScroll(anchor)
                .compactFocus(open: data?.tasks.roots.count ?? 0, shown: data?.tasks.isEmpty == false, position: $position)
                .debugScrollsToOlder(proxy, ready: board.arrangement != nil)
        }
        .onChange(of: SelectableKey(active: active, ids: board.arrangement.map { $0.pinned + $0.wall + $0.older }), initial: true) { _, key in
            if key.active, let ids = key.ids { workspace.presses.selectable = ids }
        }
        .observing(services.store, id: projectID, into: dataBinding, onError: workspace.fail) { [projectID] store in
            try ProjectPageData.read(projectID, from: store)
        }
        .onDayChange { rearrange() }
        .task(id: board.arrangement != nil) {
            guard board.arrangement != nil else { return }
            for next in Stage.allCases where next > stage {
                await NextFrame.wait()
                stage = next
            }
            DebugHooks.mark("content")
        }
    }

    @ViewBuilder private var content: some View {
        ProjectSplit(project: data?.project, gap: Spacing.section) {
            if let data, board.arrangement != nil { page(data) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.page).padding(.top, Spacing.pageTop).padding(.bottom, Self.bottomClearance)
        .cardDragStage()
    }

    @ViewBuilder
    private func page(_ data: ProjectPageData) -> some View {
        if stage >= .focus { ProjectTasks(data: data, position: $position, anchor: anchor) }
        if stage >= .wall { ProjectWallSections(data: data, board: board, showsOlder: stage >= .older) }
    }

    private var dataBinding: Binding<ProjectPageData?> {
        Binding(get: { data }, set: { data = $0; rearrange() })
    }

    private func rearrange() {
        if let data { WallBoard.rearrange($board, with: data, project: projectID, reduceMotion: reduceMotion) }
    }
}

private struct SelectableKey: Equatable {
    let active: Bool
    let ids: [UUID]?
}

#endif
