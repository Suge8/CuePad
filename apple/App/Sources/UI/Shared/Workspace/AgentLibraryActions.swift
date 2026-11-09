import CueStore
import Foundation

/// 文件只由那台 Mac 写：别的设备发投送请求（`DeliveryMode.tidy`、`.libraryEdit`）、等它写回结果。
extension Workspace {
    /// 按 `host` 那台 Mac 分开：Cue 换到另一台后看的是那台的文件，在这台没发的字不拿去对着那台。
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

    func rules(of project: UUID) -> LibraryFile? {
        library?.instruction(.project(project)) == nil ? nil : .instruction(.project(project))
    }

    func draft(of file: LibraryFile, in library: AgentLibrary?) -> FileDraft? {
        library.flatMap { fileDrafts[FileDraftKey(host: $0.hostID, file: file)] }
    }

    /// 手机发往那台 Mac 的不带撤销：那台照做不留撤销（`TidyConsequence`）。
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

    /// 文件已不是 `edit.base` 时抛 `AgentLibraryError.changedOnMac`（手机发出的，原因随结果写回）。不提示：页顶那一行由调用方写。
    func saveFile(_ edit: LibraryEdit, in library: AgentLibrary) async throws {
        if library.hostID == localHost {
            #if os(macOS)
            try await services.library.write(edit)
            #endif
        } else {
            let request = try await services.requestLibraryEdit(edit, title: shownName(of: edit.file), on: library.hostID)
            let outcome = try await services.store.outcome(of: request)
            if outcome.reason == ShownText(AgentLibraryError.changedOnMac) { throw AgentLibraryError.changedOnMac }
            if let failure = outcome.failure { throw SendError.notDelivered(failure) }
        }
    }

    func shownName(of file: LibraryFile) -> String {
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

struct FileDraftKey: Hashable {
    let host: String
    let file: LibraryFile
}
