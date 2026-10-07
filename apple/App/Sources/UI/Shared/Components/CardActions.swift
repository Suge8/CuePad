import CueStore
import SwiftUI

/// 灵感操作（Mac 右键、iOS 长按与编辑页"更多"共用）：要做、打开（Mac）、置顶、复制与发送、移到项目、移到回收站。
/// 任务的操作见 `TaskActions`（编辑页里打开的任务，"要做"处写"取消要做"）。
/// 发送是平台各自的：Mac 发给当前目标，iOS 发到 Mac 与分享。
struct CardActions: View {
    let card: Card
    /// 编辑页里打开、复制与发送已在页面上，菜单不重复。
    var inEditor = false
    @Environment(Workspace.self) private var workspace
    #if os(iOS)
    @Environment(Navigation.self) private var navigation
    #endif

    var body: some View {
        let id = card.id, catalog = workspace.catalog
        Button(card.isTask ? "取消要做" : "要做", systemImage: card.isTask ? "lightbulb" : "checklist") { workspace.toggleTodo(id, !card.isTask) }
        #if os(macOS)
        if !inEditor { Button("打开", systemImage: "arrow.up.left.and.arrow.down.right") { workspace.openCard = id } }
        #endif
        Button(card.isPinned ? "取消置顶" : "置顶", systemImage: card.isPinned ? "pin.slash" : "pin") {
            let pinned = !card.isPinned
            workspace.perform { try await $0.updateCard(id) { $0.isPinned = pinned } }
        }
        if !inEditor {
            Divider()
            sending
        }
        Menu("移到项目", systemImage: "folder") {
            ForEach(catalog?.projects ?? []) { project in
                Button(project.name) { workspace.perform { try await $0.moveCard(id, to: .top(project: project.id), after: nil) } }
                    .disabled(project.id == card.projectID)
            }
            Button("未归档") { workspace.perform { try await $0.moveCard(id, to: .top(project: nil), after: nil) } }
                .disabled(card.projectID == nil)
        }
        Divider()
        Button("移到回收站", systemImage: "trash", role: .destructive) {
            if workspace.openCard == id { workspace.openCard = nil }
            workspace.perform { try await $0.trashCard(id) }
        }
    }

    @ViewBuilder private var sending: some View {
        let text = Outgoing.text(of: card), id = card.id
        #if os(macOS)
        Button("复制", systemImage: "doc.on.doc") { Task { await workspace.send(text, via: .clipboard, card: id) } }
        let choice = workspace.effectiveChoice(for: card.projectID)
        workspace.sendButton(choice) { Task { await workspace.send(text, via: choice, card: id) } }
        #else
        Button("复制", systemImage: "doc.on.doc") { workspace.copy(card) }
        Button("发到 Mac", systemImage: "paperplane") {
            navigation.outbox = Navigation.Outbox(content: text, card: id, project: card.projectID)
        }
        ShareLink(item: text) { Label("分享", systemImage: "square.and.arrow.up") }
        #endif
    }
}
