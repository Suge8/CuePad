#if os(macOS)
import CuePi
import CueStore
import Foundation

/// 这台 Mac 的技能与说明（同步表 agentLibraries）只经这里写：跟着文件与绑定的文件夹变化重读（`AgentLibraryFiles.keep`），
/// 内容变了才写、写了立即上传；整理与改说明（本机界面、手机的投送请求）都经这里做，做完的文件变化照样经重读写进库。各处读库，这里不留结果。
@MainActor
final class AgentLibraryKeeper {
    private let store: CueStore
    private let sync: (any SyncControlling)?
    private let host: String
    private let files: AgentLibraryFiles

    init(store: CueStore, sync: (any SyncControlling)?, host: String, files: AgentLibraryFiles) {
        self.store = store
        self.sync = sync
        self.host = host
        self.files = files
    }

    /// 直到所在任务取消。碰不得几家共读的目录（隔离运行而它是真实位置）时什么都不读、不写。
    func keep() async throws {
        guard files.isAvailable else { return }
        try await files.keep(host: host, projects: store.observe { try $0.projectDirectories() }) { library in try await self.record(library) }
    }

    private func record(_ library: AgentLibrary) async throws {
        if let id = try await store.recordAgentLibrary(library) { await sync?.upload(id) }
    }

    /// 整理这几件：返回做了几件与撤销（恢复这一次的全部改动）。
    func tidy(_ orders: [TidyOrder]) async throws -> (count: Int, undo: Undo) {
        let done = try await files.tidy(orders, projects: try await store.projectDirectories())
        return (done.count, { [files] in try await files.undo(done.undo) })
    }

    /// 写一份说明；文件已不是 `edit.base` 时抛 `AgentLibraryError.changedOnMac`。
    func write(_ edit: InstructionEdit) async throws {
        try await files.write(edit, projects: try await store.projectDirectories())
    }
}
#endif
