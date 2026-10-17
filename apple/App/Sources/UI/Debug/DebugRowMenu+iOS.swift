#if os(iOS) && DEBUG
import CueStore
import SwiftUI

/// `-CuePadRowMenu <task|done|card|project>`：列表行长按出来的那一份菜单（任务、灵感用 `CardActions` 的长按版、项目用 `ProjectActions`），
/// 装进窗口正中一个看不见的菜单按钮里，配 `-CuePadMenuAt` 点在窗口中心就弹出来（`openMenuIfAsked`）。
/// 行上的长按菜单是 SwiftUI 按住才装上的，从代码打不开；菜单项与长按时一模一样（同一个视图、同一份 `CardMenu.sections`），只是不经长按手势、不带被按住那一行的预览。
/// 任务取 `-CuePadProject` 项目里最近改过的一条待办任务（done 取做完的），灵感取同一项目里最近改过的一条散放的灵感。
struct DebugRowMenu: View {
    let kind: String
    @Environment(Workspace.self) private var workspace
    @State private var card: Card?

    var body: some View {
        let project = workspace.catalog?.projects.first { $0.name == DebugScene.defaults.string(forKey: "CuePadProject") }
        Menu {
            if kind == "project" {
                if let project { ProjectActions(project: project) {} }
            } else if let card {
                CardActions(card: card)
            }
        } label: {
            Color.clear.frame(width: 44, height: 44).contentShape(.rect)
        }
        // 项目目录启动后才到：等它到了再取那张卡
        .task(id: project?.id) {
            guard kind != "project", let project else { return }
            let store = workspace.services.store
            let cards = (try? await kind != "card" ? store.tasks(in: project.id, kind == "done" ? .done : .todo) : store.cards(in: project.id)) ?? []
            card = cards.max { $0.modifiedAt < $1.modifiedAt }
        }
    }
}
#endif
