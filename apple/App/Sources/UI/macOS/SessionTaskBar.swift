#if os(macOS)
import CueStore
import SwiftUI

/// 会话页顶上一条：这个会话做的是哪件事。绑着任务时写"← 任务 › 步骤"（点它回到项目页、任务浮窗停在这一步）和"完成任务"
/// （完成就是做完了，会话随之结束，见 `Workspace.toggle`）；没绑时只有一个小的"绑定到任务"：本项目还没开始的叶子任务，
/// 或用会话名新建一个任务绑上。
struct SessionTaskBar: View {
    let sessionID: String
    let projectID: UUID?
    let title: String
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var link: SessionTaskLink?

    var body: some View {
        HStack(spacing: 10) {
            if let task = link?.task {
                Button { back(to: task) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                        Text(Dotted(link?.parent?.title, task.title)).lineLimit(1)
                    }
                    .font(Typography.meta.weight(.medium)).foregroundStyle(palette.ink2)
                    .padding(.horizontal, 10).frame(height: 26)
                    .glass(in: .capsule, interactive: true)
                }
                .buttonStyle(PressStyle())
                .help("回到这件事")
                Spacer(minLength: 8)
                if task.status == .done {
                    Label("已完成", systemImage: "checkmark.circle.fill").font(Typography.meta).foregroundStyle(palette.ink3)
                } else {
                    Button { complete(task) } label: {
                        Label("完成任务", systemImage: "checkmark").font(Typography.meta.weight(.semibold)).foregroundStyle(palette.ink)
                            .padding(.horizontal, 12).frame(height: 26)
                            .glass(in: .capsule, interactive: true)
                    }
                    .buttonStyle(PressStyle())
                    .help("这件事做完了：打勾，并结束这个会话")
                }
            } else if let link {
                Spacer(minLength: 8)
                bindMenu(link.bindable)
            }
        }
        .frame(height: 30)
        .observing(services.store, id: sessionID, into: $link, onError: workspace.fail) { [sessionID, projectID] in
            try SessionTaskLink.read(sessionID: sessionID, project: projectID, from: $0)
        }
    }

    private func bindMenu(_ tasks: [BindableTask]) -> some View {
        Menu {
            ForEach(tasks) { item in
                Button(Dotted(item.parent?.title, item.task.title).visible) { bind(to: item.task.id) }
            }
            if !tasks.isEmpty { Divider() }
            Button("新建任务并绑定", systemImage: "plus", action: bindNew)
        } label: {
            Label("绑定到任务", systemImage: "link").font(Typography.meta.weight(.medium)).foregroundStyle(palette.ink2)
                .padding(.horizontal, 10).frame(height: 26)
                .glass(in: .capsule, interactive: true)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private func back(to task: Card) {
        workspace.show(task.projectID.map(Route.project) ?? .unfiled)
        workspace.open(task)
    }

    private func complete(_ task: Card) {
        let id = task.id
        workspace.attempt { try await workspace.toggle(id) }
    }

    /// 绑上；任务里写好没发的话挪进这个会话的回复框，由你决定发不发。
    private func bind(to task: UUID) {
        let store = services.store, settings = services.settings, sessionID = sessionID
        workspace.attempt {
            if let text = try await store.bindSession(sessionID, to: task) {
                settings.setReplyDraft(ComposerDraft(text: text), for: PiSessionState.recordID(sessionID: sessionID))
            }
        }
    }

    private func bindNew() {
        let store = services.store, sessionID = sessionID, title = title, project = projectID
        workspace.attempt {
            let task = try await workspace.createTask(title, in: project)
            try await store.bindSession(sessionID, to: task.id)
        }
    }
}

/// 会话绑着的任务（和它的上级），没绑时本项目能绑的任务。
nonisolated struct SessionTaskLink: Sendable, Equatable {
    var task: Card?
    var parent: Card?
    var bindable: [BindableTask]

    static func read(sessionID: String, project: UUID?, from store: isolated CueStore) throws -> SessionTaskLink {
        let task = try store.task(boundTo: sessionID)
        return SessionTaskLink(
            task: task, parent: try task?.parentID.flatMap { try store.card($0) },
            bindable: task == nil ? try store.bindableTasks(in: project) : [])
    }
}
#endif
