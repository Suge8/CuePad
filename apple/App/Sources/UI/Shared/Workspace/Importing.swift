import CueEditor
import SwiftUI

/// 输入框里在存的附件（选好的文件要先存进附件目录，大文件要读一遍算哈希）。草稿里只记在途的编号（`ComposerDraft.importing`），
/// 存好的文件按编号找回：
/// - 存好时编号还在这份草稿里，附件接进这份草稿；
/// - 存好前这份草稿已经发出（或被取走），发的人按编号等它存好，连同附件一起发出（`claimImports`）——附件不落进下一条草稿，也不丢。
/// 发送钮不因导入而停用。
final class Imports {
    fileprivate var running: [UUID: Task<[DraftFile], Never>] = [:]
}

/// 取走一份草稿时它在途的导入：任务当场取下（导入一完成就会撤掉自己），之后 `settled()` 等它们存好，附件并进草稿。
struct ImportClaim {
    fileprivate let draft: ComposerDraft
    fileprivate let tasks: [Task<[DraftFile], Never>]

    var isEmpty: Bool { tasks.isEmpty }

    func settled() async -> ComposerDraft {
        var draft = draft
        draft.importing = []
        for task in tasks { draft.files += await task.value.filter { !draft.files.contains($0) } }
        return draft
    }
}

extension Workspace {
    /// 存进附件目录（后台）再接进 `box` 的附件条；已带着的不重复。存不了的提示，其余照常接上。
    func importFiles(_ incoming: [IncomingFile], into box: Binding<ComposerDraft>) {
        let id = UUID(), files = services.store.files
        let task = Task {
            await DebugHooks.importDelay()
            var stored: [DraftFile] = []
            for item in incoming {
                do { stored.append(try await DraftFile.store(item, in: files)) } catch { fail(error) }
            }
            return stored
        }
        imports.running[id] = task
        box.wrappedValue.importing.append(id)
        Task {
            let stored = await task.value
            imports.running[id] = nil
            // 编号不在了：这份草稿已经发出，发的人在等这个任务
            var draft = box.wrappedValue
            guard let index = draft.importing.firstIndex(of: id) else { return }
            draft.importing.remove(at: index)
            draft.files += stored.filter { !draft.files.contains($0) }
            box.wrappedValue = draft
        }
    }

    /// 取走 `draft` 时调（和取走在同一个同步步骤里）。
    func claimImports(_ draft: ComposerDraft) -> ImportClaim {
        ImportClaim(draft: draft, tasks: draft.importing.compactMap { imports.running[$0] })
    }
}
