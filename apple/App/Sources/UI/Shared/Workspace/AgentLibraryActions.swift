import CueStore
import Foundation

/// 技能与说明的动作（两端同一个入口，读的是 `Workspace.library`，规则见 `AgentLibrary`）：文件只由那台 Mac 写——本机的直接做，
/// 别的设备发投送请求（`DeliveryMode.tidy`、`.instruction`）、等那台写回结果。
extension Workspace {
    /// 整理几件（"全部整理"是 `library.automaticOrders`；同名那件带上留哪份，`TidyOrder.keep`）。不弹确认：
    /// 本机做完提示"整理好了 N 件"，带撤销（恢复这一次的全部改动，移走的从废纸篓放回）；手机发往那台 Mac，等它做完再提示，不带撤销（那台照做不留撤销，手机上按钮附近写明，`RemoteTidyNote`）。没成提示原因。
    /// 其中有几份说明合成一份的（内容不同的全局规则、项目里另一份 CLAUDE.md）：按段并集的合成稿常有重复，做完直接打开合成出的那份说明，
    /// 提示里说合成稿在这里、删掉重复的——当场删改，不先挑再合。
    func tidy(_ orders: [TidyOrder], in library: AgentLibrary) async {
        guard !orders.isEmpty else { return }
        let merged = Self.mergedInstruction(orders, in: library)
        do {
            if library.hostID == localHost {
                #if os(macOS)
                let done = try await services.library.tidy(orders)
                say(Self.tidied(done.count, merged: merged != nil), action: .undo(done.undo))
                #endif
            } else {
                let request = try await services.requestTidy(orders, on: library.hostID)
                if let failure = try await services.store.outcome(of: request).failure { throw SendError.notDelivered(failure) }
                say(Self.tidied(orders.count, merged: merged != nil))
            }
            if let merged { openLibrary(.instruction(merged)) }
        } catch {
            fail(error)
        }
    }

    private static func tidied(_ count: Int, merged: Bool) -> LocalizedStringResource {
        merged ? "整理好了 \(count) 件，合成稿在这里，删掉重复的" : "整理好了 \(count) 件"
    }

    /// 这几件里合成出来的那份说明（全局的在前）；只是换成链接（内容一样）的不算。
    private static func mergedInstruction(_ orders: [TidyOrder], in library: AgentLibrary) -> LibraryInstruction.Kind? {
        let ids = Set(orders.map(\.tidy))
        let kinds = library.tidies.filter { ids.contains($0.id) }.compactMap { tidy -> LibraryInstruction.Kind? in
            switch tidy.kind {
            case .globalInstructions: tidy.differs ? .global : nil
            case .projectClaude(let project, _): .project(project)
            default: nil
            }
        }
        return kinds.first { $0 == .global } ?? kinds.first
    }

    /// 写一份说明（Mac 编辑页的自动存、手机的"发往 Mac"都调它）：`edit.base` 是改之前看到的内容（`LibraryInstruction.base`）。
    /// 文件已不是它时抛 `AgentLibraryError.changedOnMac`（手机发出的，原因随结果写回），编辑页据此跟上文件此刻的样子。
    /// 写成后快照随文件变化更新（`library`）。不提示：页顶那一行由调用方写"存好"或原因。
    func saveInstruction(_ edit: InstructionEdit, in library: AgentLibrary) async throws {
        if library.hostID == localHost {
            #if os(macOS)
            try await services.library.write(edit)
            #endif
        } else {
            let request = try await services.requestInstructionEdit(edit, title: instructionName(edit.instruction), on: library.hostID)
            let outcome = try await services.store.outcome(of: request)
            if outcome.failureReason == ShownText(AgentLibraryError.changedOnMac) { throw AgentLibraryError.changedOnMac }
            if let failure = outcome.failure { throw SendError.notDelivered(failure) }
        }
    }

    /// 一份说明的名字：全局说明、Pi 的系统提示、项目名。
    func instructionName(_ kind: LibraryInstruction.Kind) -> String {
        switch kind {
        case .global: String(localized: "全局说明")
        case .piSystem: String(localized: "Pi 的系统提示")
        case .project(let id): catalog?.project(id)?.shownName ?? String(localized: "项目说明")
        }
    }
}
