#if os(macOS)
import CuePi
import CueStore
import Foundation

/// 这台 Mac 的技能与说明（同步表 agentLibraries）只经这里写：跟着文件与绑定的文件夹变化重扫，内容变了才写、写了立即上传；
/// 整理与改说明（本机界面、手机的投送请求）都经这里做。各处读库，这里不留结果。
@MainActor
final class AgentLibraryKeeper {
    private let store: CueStore
    private let sync: (any SyncControlling)?
    private let host: String

    init(store: CueStore, sync: (any SyncControlling)?, host: String) {
        self.store = store
        self.sync = sync
        self.host = host
    }

    /// 整理这几件：返回做了几件与撤销（恢复这一次的全部改动）。
    func tidy(_ orders: [TidyOrder]) async throws -> (count: Int, undo: Undo) {
        throw AgentLibraryError.tidyGone
    }

    /// 写一份说明；文件已不是 `edit.base` 时抛 `AgentLibraryError.changedOnMac`。
    func write(_ edit: InstructionEdit) async throws {
        throw AgentLibraryError.changedOnMac
    }
}
#endif
