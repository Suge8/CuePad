#if os(iOS)
import CueStore
import SwiftUI

struct ProjectSessions: View {
    let project: UUID
    let list: SessionListData?
    @Binding var extra: Int
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let cap = 5
    static let step = 10

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.item) {
            line(.add, Text("新会话")) { workspace.openNewSession(in: project) }
            if let list {
                ForEach(list.pinned + list.now + list.ended) { item in
                    let end = list.ends[item.id], ending = end?.inTransit == true
                    SessionListRow(item: item, showsPlace: false, end: end)
                        .rowSwipes(SessionActions.swipes(item.state, task: item.task, ending: ending, in: workspace), clipped: false)
                        .contextMenu { SessionActions(session: item.state, task: item.task, ending: ending) }
                }
                if list.hasMore {
                    line(.expand, Text("更早的会话"), count: list.endedTotal - list.ended.count) {
                        withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { extra += Self.step }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func line(_ icon: Icon, _ title: Text, count: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: TaskMetrics.columnGap) {
                Image(icon).font(Glyph.small).frame(width: TaskMetrics.ringColumn)
                title.font(Typography.body)
                if let count { Text(count, format: .number).font(Typography.body) }
                Spacer(minLength: 0)
            }
            .foregroundStyle(palette.ink3)
            .frame(minHeight: TaskMetrics.rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.row)
        .padding(.leading, -TaskMetrics.ringInset)
    }
}
#endif
