import CueStore
import os

/// 进程只建一个 `AppServices`，所有窗口共用。资料库打不开时（连位置都解析不出来也一样）不终止进程：失败页给原因、重试与诊断，两端同一个样子。
enum Launch {
    case ready(AppServices)
    case failed(LibraryFailure)
    #if os(iOS)
    /// 作为单元测试宿主：不开库（Mac 的测试宿主不建 `AppDelegate`，`MacMain`）。
    case testHost
    #endif

    static func make(_ open: (LibraryLocation) throws -> AppServices) -> Launch {
        var location: LibraryLocation?
        do {
            let resolved = try LibraryLocation.resolve()
            location = resolved
            return .ready(try open(resolved))
        } catch {
            // 位置本身解析不出来（比如没有 App Group 权限）时没有库文件可读，失败里的版本为空
            let failure = LibraryFailure(error, location: location)
            Logger(subsystem: AppIdentity.id, category: "launch").error("资料库没能打开：\(failure.reason, privacy: .public)")
            DebugHooks.libraryFailed(failure)
            return .failed(failure)
        }
    }

    var services: AppServices? {
        if case .ready(let services) = self { services } else { nil }
    }
}
