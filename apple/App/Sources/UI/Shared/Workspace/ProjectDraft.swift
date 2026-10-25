import CueStore
import Foundation

/// 项目表单的内容，两端同一份（Mac 的 `ProjectForm`、手机的 `ProjectFormSheet`），从打开表单的那次请求（`ProjectFormRequest`）起草：新建时是默认图标与第一种颜色，编辑时预填这个项目；
/// 名称去掉首尾空白后不能是空的，一句话介绍空白即没有。新建时绑哪个文件夹两端不同（Mac 本机选，手机请那台 Mac 绑），由保存时的 `created` 接着做。
struct ProjectDraft {
    let project: Project?
    var name: String
    var intro: String
    var icon: ProjectIcon
    var color: String

    static let namePrompt = String(localized: "名称")
    static let introPrompt = String(localized: "一句话介绍（可不填）")

    init(_ request: ProjectFormRequest) {
        let project = request.project
        self.project = project
        name = project?.shownName ?? ""
        intro = project?.intro ?? ""
        icon = ProjectIcon(stored: project?.icon)
        color = project?.color ?? Palette.projectColors[0].stored
    }

    var title: String { project == nil ? String(localized: "新建项目") : String(localized: "编辑项目") }
    var confirm: String { project == nil ? String(localized: "创建") : String(localized: "保存") }
    var canSave: Bool { !trimmedName.isEmpty }

    var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    /// 写进库（出错交给 `attempt`），名称是空的不写、返回 false（表单不关）；新建的项目建好后调 `created`。
    func save(in workspace: Workspace, created: @escaping @MainActor (UUID) async throws -> Void) -> Bool {
        guard canSave else { return false }
        // 名字没改就留存的那份：默认项目显示的是这台设备语言的名字，原样存回去就成了改名
        let name = trimmedName == project?.shownName ? project?.name ?? trimmedName : trimmedName
        let store = workspace.services.store, existing = project?.id, icon = icon.rawValue, color = color
        let intro = intro.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        workspace.attempt {
            let id = if let existing { existing } else { try await store.createProject(name: name, color: color, icon: icon).id }
            try await store.updateProject(id) { $0.name = name; $0.intro = intro; $0.icon = icon; $0.color = color }
            if existing == nil { try await created(id) }
        }
        return true
    }
}
