import CueStore
#if os(macOS)
import AppKit
#endif

extension LibraryLocation {
    var touchesRealWorld: Bool {
        switch origin {
        case .release: true
        case .development: !Self.releaseInstalled
        case .override:
            switch DebugHooks.args.actsAs {
            case nil: false
            case .development?: !Self.releaseInstalled
            case .stranger?: true
            }
        }
    }

    /// 这台 Mac 上装着正式版：LaunchServices 按 bundle id 登记的副本里有正式版（`AppIdentity.isRelease`）。本机构建与正式版同一个 bundle id，
    /// 按包里的正式版标记分。装进"应用程序"、~/Applications 或打开过一次的都已登记；拷到别处、从没打开过的找不到，算没装。
    private static let releaseInstalled: Bool = {
        #if os(macOS)
        guard let id = Bundle.main.bundleIdentifier else { return false }
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).contains { AppIdentity.isRelease(at: $0) }
        #else
        false
        #endif
    }()
}
