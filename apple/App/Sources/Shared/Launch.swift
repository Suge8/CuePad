import CueStore
import os

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
