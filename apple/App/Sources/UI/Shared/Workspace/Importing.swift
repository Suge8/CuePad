import CueEditor
import SwiftUI

final class Imports {
    fileprivate var running: [UUID: Task<[DraftFile], Never>] = [:]
}

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
            var draft = box.wrappedValue
            guard let index = draft.importing.firstIndex(of: id) else { return }
            draft.importing.remove(at: index)
            draft.files += stored.filter { !draft.files.contains($0) }
            box.wrappedValue = draft
        }
    }

    func claimImports(_ draft: ComposerDraft) -> ImportClaim {
        ImportClaim(draft: draft, tasks: draft.importing.compactMap { imports.running[$0] })
    }
}
