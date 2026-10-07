import CueStore
import SwiftUI

/// 打开的任务在编辑器正文上方多出的一块（手机任务浮窗、Mac 纸页共用）：状态（点它换）、交给 Agent 的会话此刻在做什么，
/// 下面是它的下级——子任务（圆圈可勾）与素材（挂在它下面的灵感），点一条打开它；最后一行添加子任务。
struct TaskPanel: View {
    let task: Card
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    #if os(iOS)
    @Environment(Navigation.self) private var navigation
    #endif
    @State private var detail: TaskDetail?
    @State private var newSubtask = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                statusMenu
                if let session = detail?.session { sessionChip(session) }
                Spacer(minLength: 0)
            }
            ForEach(detail?.children ?? []) { child in childRow(child) }
            HStack(spacing: 8) {
                Image(systemName: "plus").foregroundStyle(palette.ink3).frame(width: Self.icon).accessibilityHidden(true)
                TextField("添加子任务", text: $newSubtask).textFieldStyle(.plain).onSubmit(addSubtask)
            }
            .frame(minHeight: Self.rowHeight)
        }
        .font(Self.font)
        .observing(services.store, TaskDetail.tables, id: task.id, into: $detail, onError: workspace.fail) { [id = task.id] in
            try TaskDetail.read(id, from: $0)
        }
        #if os(macOS)
        .modifier(SessionDetailHost(arrowEdge: .bottom))
        #endif
    }

    #if os(iOS)
    private static let font = Font.subheadline
    private static let icon: CGFloat = 28
    private static let rowHeight: CGFloat = 40
    #else
    private static let font = Font.system(size: 13)
    private static let icon: CGFloat = 16
    private static let rowHeight: CGFloat = 24
    #endif

    private var statusMenu: some View {
        Menu {
            let id = task.id
            ForEach([TaskStatus.todo, .inProgress, .done], id: \.self) { status in
                Button(TaskSpeech.value(status)) { workspace.perform { try await $0.setStatus(id, status) } }
                    .disabled(task.status == status)
            }
            Divider()
            Button("取消要做", systemImage: "lightbulb") { workspace.toggleTodo(id, false) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: Self.symbol(task.status)).foregroundStyle(task.status == .done ? palette.accent : palette.ink2)
                Text(TaskSpeech.value(task.status)).foregroundStyle(palette.ink)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(palette.ink3).accessibilityHidden(true)
            }
            .padding(.horizontal, 10).frame(minHeight: 30)
            .background(palette.fill, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .menuStyle(.button).menuIndicator(.hidden).fixedSize()
        #endif
        .accessibilityLabel("状态 \(TaskSpeech.value(task.status))")
    }

    @ViewBuilder private func sessionChip(_ session: PiSessionState) -> some View {
        let shown = services.settings.shown(session, delivery: detail?.delivery)
        let label = HStack(spacing: 4) {
            PiStateDot(shown: shown, size: 6)
            Text(shown.presence).foregroundStyle(shown.tint(palette))
            PiElapsed(session: session, font: .caption)
        }
        .font(.caption).lineLimit(1).fixedSize()
        #if os(iOS)
        Button { navigation.openSession(session.id, sessionID: session.sessionID, store: services.store) } label: { label }
            .buttonStyle(.plain)
            .accessibilityHint("看 Agent 的近况")
        #else
        label.sessionDetailRow(session.sessionID).help("交给了 Pi 会话「\(session.title)」，点开看近况")
        #endif
    }

    private func childRow(_ child: Card) -> some View {
        HStack(spacing: 8) {
            if child.isTask {
                Button {
                    workspace.attempt { try await workspace.toggle(child) }
                } label: {
                    Image(systemName: Self.symbol(child.status))
                        .foregroundStyle(child.status == .done ? palette.accent : palette.ink3)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: Self.icon, height: Self.rowHeight).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(TaskSpeech.toggle(done: child.status == .done))
            } else {
                Image(systemName: "doc.text").foregroundStyle(palette.ink3).frame(width: Self.icon).accessibilityLabel("素材")
            }
            open(child) {
                Text(child.title)
                    .strikethrough(child.status == .done)
                    .foregroundStyle(child.status == .done ? palette.ink3 : palette.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
                    .contentShape(.rect)
            }
        }
        .sensoryFeedback(.success, trigger: child.status) { $1 == .done }
    }

    /// 打开一条下级：手机推进浮窗里（浮窗与主栈都认 `.card`），Mac 换成这张纸。
    @ViewBuilder private func open(_ child: Card, @ViewBuilder label: () -> some View) -> some View {
        #if os(iOS)
        NavigationLink(value: Navigation.Route.card(child.id), label: label).buttonStyle(.plain)
        #else
        Button(action: { workspace.openCard = child.id }, label: label).buttonStyle(.plain)
        #endif
    }

    private func addSubtask() {
        let body = newSubtask.trimmingCharacters(in: .whitespaces), parent = task.id
        guard !body.isEmpty else { return }
        newSubtask = ""
        workspace.perform { _ = try await $0.createTask(body, under: parent) }
    }

    static func symbol(_ status: TaskStatus?) -> String {
        switch status {
        case .done: "checkmark.circle.fill"
        case .inProgress: "circle.lefthalf.filled"
        case .todo, nil: "circle"
        }
    }
}

/// 一条任务的下级与它交给的会话，任务浮窗与纸页上的 `TaskPanel` 读它。
nonisolated struct TaskDetail: Sendable, Equatable {
    /// 子任务与素材，同级手动顺序（任务与灵感混排，按用户放的位置）。
    var children: [Card]
    var session: PiSessionState?
    var delivery: DeliveryRequest?

    static let tables: Set<StoreTable> = [.cards, .piSessionStates, .deliveryRequests]

    static func read(_ id: UUID, from store: isolated CueStore) throws -> TaskDetail {
        let item = try store.card(id)?.piSessionID.flatMap {
            try store.piSessionPage(PiSessionQuery(id: PiSessionState.recordID(sessionID: $0))).items.first
        }
        return TaskDetail(children: try store.children(of: id), session: item?.state, delivery: item?.delivery)
    }
}
