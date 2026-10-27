import CueStore
import Foundation

/// 技能与规则的动作（两端同一个入口，读的是 `Workspace.library`，规则见 `AgentLibrary`）：文件只由那台 Mac 写——本机的直接做，
/// 别的设备发投送请求（`DeliveryMode.tidy`、`.libraryEdit`）、等那台写回结果。
extension Workspace {
    /// 一份文件的文件页（两端同一份，`FileDraft`）：改着的、标着合并的都留在这里，离开文件页再回来接着——手机上不点纸飞机就不发，也不丢（App 退出才没了）。
    /// 按 `host` 那台 Mac 分开：Cue 换到另一台后看的是那台的文件，在这台没发的字不拿去对着那台。
    /// 再打开时先对上快照里此刻的样子（没改过就跟上，改着的就说文件变了）。
    func fileDraft(_ file: LibraryFile, text: String?, on host: String) -> FileDraft {
        let key = FileDraftKey(host: host, file: file)
        if let draft = fileDrafts[key] {
            draft.follow(text)
            return draft
        }
        let draft = FileDraft(file, text: text, workspace: self)
        fileDrafts[key] = draft
        return draft
    }

    /// 这个项目的规则文件（绑着文件夹、快照里有它的 AGENTS.md）：有才有。项目页、项目菜单里的"规则"入口都问它，点了 `openLibrary`。
    func rules(of project: UUID) -> LibraryFile? {
        library?.instruction(.project(project)) == nil ? nil : .instruction(.project(project))
    }

    /// 这份文件此刻改着的那一份；文件页还没载入（正文没到）时为 nil。
    func draft(of file: LibraryFile, in library: AgentLibrary?) -> FileDraft? {
        library.flatMap { fileDrafts[FileDraftKey(host: $0.hostID, file: file)] }
    }

    /// 整理：一键整理（`library.automaticOrders`）、去重（带上留哪份，`TidyOrder.keep`）、合并（`LibraryTidy.merges` 的那件）。不弹确认：
    /// 本机做完提示结果，带撤销（恢复这一次的全部改动，移走的从废纸篓放回）；手机发往那台 Mac，等它做完再提示，不带撤销
    /// （那台照做不留撤销，手机上按钮旁写明，`TidyConsequence`）。没成提示原因。合并后的那份规则就在开着的文件页里，跟着快照换成合并稿。
    func tidy(_ orders: [TidyOrder], in library: AgentLibrary) async {
        guard !orders.isEmpty else { return }
        do {
            if library.hostID == localHost {
                #if os(macOS)
                let done = try await services.library.tidy(orders)
                say(Self.tidied(orders, count: done.count, in: library), action: .undo(done.undo))
                #endif
            } else {
                let request = try await services.requestTidy(orders, on: library.hostID)
                if let failure = try await services.store.outcome(of: request).failure { throw SendError.notDelivered(failure) }
                say(Self.tidied(orders, count: orders.count, in: library))
            }
        } catch {
            fail(error)
        }
    }

    private static func tidied(_ orders: [TidyOrder], count: Int, in library: AgentLibrary) -> LocalizedStringResource {
        if orders.contains(where: { $0.keep != nil }) { return "只留了这份，其余进了废纸篓" }
        let ids = Set(orders.map(\.tidy))
        if library.tidies.contains(where: { ids.contains($0.id) && $0.merges }) { return "合并好了" }
        return "整理好了 \(count) 件"
    }

    /// 改一份技能或规则文件（Mac 文件页的自动存、手机的"发往 Mac"都调它）：`edit.base` 是改之前看到的内容（`LibraryEdit.base`）。
    /// 文件已不是它时抛 `AgentLibraryError.changedOnMac`（手机发出的，原因随结果写回），文件页据此跟上文件此刻的样子。
    /// 写成后快照随文件变化更新（`library`）。不提示：页顶那一行由调用方写"存好"或原因。
    func saveFile(_ edit: LibraryEdit, in library: AgentLibrary) async throws {
        if library.hostID == localHost {
            #if os(macOS)
            try await services.library.write(edit)
            #endif
        } else {
            let request = try await services.requestLibraryEdit(edit, title: fileName(edit.file), on: library.hostID)
            let outcome = try await services.store.outcome(of: request)
            if outcome.failureReason == ShownText(AgentLibraryError.changedOnMac) { throw AgentLibraryError.changedOnMac }
            if let failure = outcome.failure { throw SendError.notDelivered(failure) }
        }
    }

    /// 一份文件的名字：技能是它的目录名；规则是全局规则、Pi 的系统提示、项目名。
    func fileName(_ file: LibraryFile) -> String {
        switch file {
        case .skill(let path): (path as NSString).lastPathComponent
        case .instruction(let kind): instructionName(kind)
        }
    }

    func instructionName(_ kind: LibraryInstruction.Kind) -> String {
        switch kind {
        case .global: String(localized: "全局规则")
        case .piSystem: String(localized: "Pi 的系统提示")
        case .project(let id): catalog?.project(id)?.shownName ?? String(localized: "项目规则")
        }
    }
}

/// 改着的一份文件是哪台 Mac 的哪一份（`Workspace.fileDrafts`）。
struct FileDraftKey: Hashable {
    let host: String
    let file: LibraryFile
}
