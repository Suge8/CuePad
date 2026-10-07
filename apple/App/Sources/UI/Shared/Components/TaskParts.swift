import CueStore
import SwiftUI
#if os(iOS)
import PhotosUI
#else
import AppKit
#endif

// 任务浮窗（手机半屏、Mac 弹出）与 Mac 纸页共用的几块：任务就是给 Agent 的话，正文是焦点；
// 这里是正文周围的次要信息——状态、Agent（交给的会话与发出记录）、下级（子任务与素材）。

/// 一条任务的下级、交给的会话与发出记录：浮窗与纸页一次读出，各块只画。
nonisolated struct TaskDetail: Sendable, Equatable {
    /// 子任务与素材，同级手动顺序（任务与灵感混排，按用户放的位置）。
    var children: [Card]
    /// 能挑来作素材的：本项目散放的灵感，最近改过的在前。
    var ideas: [Card]
    var session: PiSessionState?
    var delivery: DeliveryRequest?
    /// 每一次发出去的原文，最近的在前。
    var sends: [SendRecord]

    static let tables: Set<StoreTable> = [.cards, .piSessionStates, .deliveryRequests, .sendRecords]

    static let ideaLimit = 20

    static func read(_ id: UUID, from store: isolated CueStore) throws -> TaskDetail {
        let task = try store.card(id)
        let item = try task?.piSessionID.flatMap {
            try store.piSessionPage(PiSessionQuery(id: PiSessionState.recordID(sessionID: $0))).items.first
        }
        let ideas = try store.cards(in: task?.projectID).sorted { $0.modifiedAt > $1.modifiedAt }.prefix(ideaLimit)
        return TaskDetail(
            children: try store.children(of: id), ideas: Array(ideas), session: item?.state, delivery: item?.delivery,
            sends: try store.sendRecords(card: id))
    }

    var subtasks: [Card] { children.filter(\.isTask) }
    var materials: [Card] { children.filter { !$0.isTask } }

    /// 下级一行的说明："子任务 1/2 · 素材 1"；都没有时引导添加。
    var subitemsSummary: String {
        let parts = [
            subtasks.isEmpty ? nil : "子任务 \(subtasks.filter { $0.status == .done }.count)/\(subtasks.count)",
            materials.isEmpty ? nil : "素材 \(materials.count)",
        ].compactMap { $0 }
        return parts.isEmpty ? "添加子任务或素材" : parts.joined(separator: " · ")
    }
}

/// 状态：点开换成待办 / 进行中 / 已完成，或取消要做。
struct TaskStatusMenu: View {
    let task: Card
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
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
                Image(systemName: TaskGlyph.symbol(task.status)).foregroundStyle(task.status == .done ? palette.accent : palette.ink2)
                    .contentTransition(.symbolEffect(.replace))
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
}

/// Agent 一行：交给的会话此刻在做什么（点开看近况），右边是发出过几次（点开看每一版原文）。
struct TaskAgentStrip: View {
    let detail: TaskDetail?
    let showSends: () -> Void
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    #if os(iOS)
    @Environment(Navigation.self) private var navigation
    #endif

    var body: some View {
        HStack(spacing: 10) {
            TaskSectionLabel(text: "Agent")
            if let session = detail?.session {
                sessionChip(session)
            } else {
                Text("还没交给 Agent").foregroundStyle(palette.ink3)
            }
            Spacer(minLength: 8)
            if let sends = detail?.sends, !sends.isEmpty {
                Button(action: showSends) {
                    HStack(spacing: 3) {
                        Text("发出 \(sends.count) 次").monospacedDigit()
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).accessibilityHidden(true)
                    }
                    .foregroundStyle(palette.ink2)
                    .frame(minHeight: TaskMetrics.rowHeight).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("看每一次发出去的原文")
            }
        }
        .font(TaskMetrics.font)
        .frame(minHeight: TaskMetrics.rowHeight)
    }

    @ViewBuilder private func sessionChip(_ session: PiSessionState) -> some View {
        let shown = services.settings.shown(session, delivery: detail?.delivery)
        let label = HStack(spacing: 5) {
            PiStateDot(shown: shown, size: 7)
            Text(session.title).foregroundStyle(palette.ink).lineLimit(1)
            Text(shown.presence).foregroundStyle(shown.tint(palette)).lineLimit(1)
            PiElapsed(session: session, font: .caption)
        }
        .fixedSize(horizontal: false, vertical: true)
        #if os(iOS)
        Button { navigation.openSession(session.id, sessionID: session.sessionID, store: services.store) } label: { label }
            .buttonStyle(.plain)
            .accessibilityHint("看 Agent 的近况")
        #else
        label.sessionDetailRow(session.sessionID).help("交给了 Pi 会话「\(session.title)」，点开看近况")
        #endif
    }
}

/// 下级一行："子任务 1/2 · 素材 1"，点开看全部、添加。
struct TaskSubitemsRow: View {
    let detail: TaskDetail?
    let expanded: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                TaskSectionLabel(text: "下级")
                Text(detail?.subitemsSummary ?? " ").foregroundStyle(palette.ink2).monospacedDigit()
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(palette.ink3)
                    .rotationEffect(.degrees(expanded ? 90 : 0)).accessibilityHidden(true)
            }
            .font(TaskMetrics.font)
            .frame(minHeight: TaskMetrics.rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// 浮窗下方两行（Agent、下级）开头的小标签，同宽对齐。
struct TaskSectionLabel: View {
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        Text(text).font(.caption.weight(.medium)).foregroundStyle(palette.ink3)
            .frame(width: TaskMetrics.labelWidth, alignment: .leading)
    }
}

/// 给 Agent 的话还只有标题时，贴着正文的一句引导；点它从标题下面接着写。
struct PromptHint: View {
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            Label("写下要 Agent 做什么…", systemImage: "text.cursor")
                .font(TaskMetrics.font).foregroundStyle(palette.ink3)
                .frame(minHeight: TaskMetrics.rowHeight).contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// 发出记录：每一次发出去的那一版原文（发出时的快照，之后改正文不影响），最近的在前；点一条看全文。
struct SendRecordList: View {
    let records: [SendRecord]
    @Environment(\.palette) private var palette
    #if os(macOS)
    @State private var opened: UUID?
    #endif

    var body: some View {
        ForEach(records) { record in
            #if os(iOS)
            NavigationLink { SendRecordText(record: record) } label: { row(record) }
            #else
            Button { opened = opened == record.id ? nil : record.id } label: { row(record) }
                .buttonStyle(.plain)
            if opened == record.id {
                Text(record.content).font(.system(size: 12.5)).foregroundStyle(palette.ink2).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(palette.fill, in: .rect(cornerRadius: 8))
            }
            #endif
        }
    }

    private func row(_ record: SendRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(DateLabel.short(record.sentAt)).monospacedDigit().foregroundStyle(palette.ink3)
            SentMark(target: record.targetName).foregroundStyle(palette.ink2)
            Text(CardText(record.content).title).foregroundStyle(palette.ink).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(TaskMetrics.font)
        .frame(minHeight: TaskMetrics.rowHeight)
        .contentShape(.rect)
    }
}

#if os(iOS)
/// 一次发出的全文。
struct SendRecordText: View {
    let record: SendRecord
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView {
            Text(record.content).textSelection(.enabled).foregroundStyle(palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
        .background(palette.paper)
        .navigationTitle("\(DateLabel.short(record.sentAt)) 发给 \(record.targetName)")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif

/// 子任务（圆圈可勾）与素材（挂在它下面的灵感），点一条打开它；最后是添加子任务与添加素材
/// （从本项目的灵感里挑，或相册、拍照、选图片存成一条素材）。
struct TaskChildrenList: View {
    let task: Card
    let detail: TaskDetail?
    /// Mac 上点一条下级打开它（任务浮窗里换成它，纸页里换一张纸）；手机经导航推进。
    var openChild: ((UUID) -> Void)?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var newSubtask = ""
    #if os(iOS)
    @State private var pickingPhotos = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var takingPhoto = false
    #endif

    private static var icon: CGFloat { TaskMetrics.icon }
    private static var rowHeight: CGFloat { TaskMetrics.rowHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(detail?.children ?? []) { child in childRow(child) }
            HStack(spacing: 8) {
                Image(systemName: "plus").foregroundStyle(palette.ink3).frame(width: Self.icon).accessibilityHidden(true)
                TextField("添加子任务", text: $newSubtask).textFieldStyle(.plain).onSubmit(addSubtask)
            }
            .frame(minHeight: Self.rowHeight)
            addMaterial
        }
        .font(TaskMetrics.font)
        #if os(iOS)
        .photosPicker(isPresented: $pickingPhotos, selection: $picked, maxSelectionCount: 9, matching: .images)
        .onChange(of: picked) { attachPicked() }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { data in attach([data]) }.ignoresSafeArea()
        }
        #endif
    }

    /// 添加素材：本项目最近的灵感挑一条挂上；或把图片存成一条素材。
    private var addMaterial: some View {
        Menu {
            let ideas = detail?.ideas ?? []
            Section(ideas.isEmpty ? "本项目还没有散放的灵感" : "从灵感里挑") {
                ForEach(ideas) { idea in
                    Button(idea.title) {
                        let id = idea.id, task = task.id
                        workspace.attempt { try await workspace.attach(id, to: task) }
                    }
                }
            }
            #if os(iOS)
            Button("相册", systemImage: "photo.on.rectangle") { pickingPhotos = true }
            if CameraPicker.isAvailable { Button("拍照", systemImage: "camera") { takingPhoto = true } }
            #else
            Button("选图片…", systemImage: "photo.on.rectangle") { chooseImages() }
            #endif
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "paperclip").foregroundStyle(palette.ink3).frame(width: Self.icon).accessibilityHidden(true)
                Text("添加素材").foregroundStyle(palette.ink3)
                Spacer(minLength: 0)
            }
            .frame(minHeight: Self.rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .menuStyle(.button).menuIndicator(.hidden)
        #endif
    }

    private func attach(_ images: [Data]) {
        let task = task
        workspace.attempt { try await workspace.attachImages(images, to: task) }
    }

    #if os(iOS)
    private func attachPicked() {
        let items = picked
        guard !items.isEmpty else { return }
        picked = []
        workspace.attempt {
            var images: [Data] = []
            for item in items { if let data = try await item.loadTransferable(type: Data.self) { images.append(data) } }
            attach(images)
        }
    }
    #else
    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        attach(panel.urls.compactMap { try? Data(contentsOf: $0) })
    }
    #endif

    private func childRow(_ child: Card) -> some View {
        HStack(spacing: 8) {
            if child.isTask {
                Button {
                    workspace.attempt { try await workspace.toggle(child) }
                } label: {
                    Image(systemName: TaskGlyph.symbol(child.status))
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

    /// 打开一条下级：手机推进浮窗里（浮窗与主栈都认 `.card`），Mac 交给 `openChild`（没给时换一张纸）。
    @ViewBuilder private func open(_ child: Card, @ViewBuilder label: () -> some View) -> some View {
        #if os(iOS)
        NavigationLink(value: Navigation.Route.card(child.id), label: label).buttonStyle(.plain)
        #else
        Button(action: { if let openChild { openChild(child.id) } else { workspace.openCard = child.id } }, label: label).buttonStyle(.plain)
        #endif
    }

    private func addSubtask() {
        let body = newSubtask.trimmingCharacters(in: .whitespaces), parent = task.id
        guard !body.isEmpty else { return }
        newSubtask = ""
        workspace.perform { _ = try await $0.createTask(body, under: parent) }
    }

}

/// 任务行标题后的小记号：给 Agent 的话写了要求是一行字的图标，交给过 Agent 是纸飞机（行上已经写着会话状态时不重复）。
/// 只有标题时什么都不画。
struct PromptMarkIcon: View {
    let mark: PromptMark
    /// 这一行已经写着交给的会话此刻的状态。
    var showsSession = false
    @Environment(\.palette) private var palette

    var body: some View {
        switch mark {
        case .written, .handedOff where !showsSession:
            Image(systemName: mark == .written ? "text.alignleft" : "paperplane")
                .font(.caption2.weight(.semibold)).foregroundStyle(palette.ink3)
                .accessibilityLabel(mark.speech ?? "")
        case .handedOff, .none: EmptyView()
        }
    }
}

/// 任务区各块的尺寸（手机按动态字体与 44pt 点按，Mac 用小字）。
enum TaskMetrics {
    #if os(iOS)
    static let font = Font.subheadline
    static let icon: CGFloat = 28
    static let rowHeight: CGFloat = 44
    static let labelWidth: CGFloat = 44
    #else
    static let font = Font.system(size: 13)
    static let icon: CGFloat = 16
    static let rowHeight: CGFloat = 26
    static let labelWidth: CGFloat = 38
    #endif
}

/// 任务的状态圆圈：待办空心、进行中半满、完成对勾。
enum TaskGlyph {
    static func symbol(_ status: TaskStatus?) -> String {
        switch status {
        case .done: "checkmark.circle.fill"
        case .inProgress: "circle.lefthalf.filled"
        case .todo, nil: "circle"
        }
    }
}
