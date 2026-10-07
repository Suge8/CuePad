#if os(macOS)
import CueStore
import CueText
import SwiftUI

/// Mac 的任务浮窗：点任务行弹出，与手机的任务浮窗同一块内容——状态、交给的会话与下级、添加子任务与素材（`TaskPanel`），
/// 下面是正文（交给 Agent 的话，边写边存），底部是交给 Agent（发送目标同底部输入栏）与"整页打开"。
/// 点下级在浮窗里换成它，左上角回到上级。
struct TaskPopover: View {
    let taskID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var shown: UUID?

    var body: some View {
        let id = shown ?? taskID
        TaskPopoverPage(cardID: id, back: id == taskID ? nil : { shown = nil }, openChild: { shown = $0 })
            .id(id)
            .frame(width: 440, height: 480)
            .background(palette.paper)
    }
}

private struct TaskPopoverPage: View {
    let cardID: UUID
    let back: (() -> Void)?
    let openChild: (UUID) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var card: Card?
    @State private var initialText: String?
    @State private var liveText = ""
    @State private var handle = EditorHandle()
    @State private var autosave: Autosave?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let card, card.isTask {
                TaskPanel(task: card, openChild: openChild)
                Divider().overlay(palette.hair)
            }
            if let initialText {
                EditorHost(
                    initialText: initialText, theme: .paper(palette, horizontalInset: 0), handle: handle,
                    onChange: { next in
                        liveText = next
                        autosave?.changed(next)
                    },
                    onError: workspace.fail)
            }
            footer
        }
        .padding(16)
        .observing(services.store, [.cards], id: cardID, into: $card, onError: workspace.fail) { [cardID] store in
            guard let card = try store.card(cardID) else { throw CueStoreError.notFound }
            return card
        }
        .onChange(of: card?.id, initial: true) {
            guard initialText == nil, let card else { return }
            initialText = card.body
            liveText = card.body
        }
        .onAppear(perform: makeAutosave)
        .onDisappear { if let autosave { Task { await autosave.flush() } } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let back {
                Button("回到上级", systemImage: "chevron.left", action: back)
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            let project = workspace.catalog?.project(card?.projectID)
            ProjectGlyph(project: project, size: 12)
            Text(project?.name ?? "未归档").foregroundStyle(palette.ink3)
            if card?.isTask == false { Text("· 素材").foregroundStyle(palette.ink3) }
            Spacer()
        }
        .font(.system(size: 12))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("整页打开", systemImage: "arrow.up.left.and.arrow.down.right") {
                workspace.overlay = nil
                workspace.openCard = cardID
            }
            .buttonStyle(.borderless).foregroundStyle(palette.ink2)
            Spacer()
            if let card {
                SendControl(project: card.projectID, compact: true) { choice in
                    let text = Outgoing.text(body: handle.text ?? liveText, values: card.variableValues), id = card.id
                    Task { await workspace.send(text, via: choice, card: id) }
                }
            }
        }
        .font(.system(size: 12))
    }

    private func makeAutosave() {
        guard autosave == nil else { return }
        let store = services.store, id = cardID
        autosave = Autosave(save: { body in try await store.updateCard(id) { $0.body = body } }, onError: workspace.fail)
    }
}
#endif
