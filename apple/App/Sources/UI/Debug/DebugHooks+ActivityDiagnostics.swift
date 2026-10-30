import Foundation

extension DebugHooks {
    /// `-CuePadActivityDiagnostics YES`：隔离库里也留活动取证；不连接 CloudKit，配现有的本地活动演示验收。
    static var recordsActivityDiagnostics: Bool {
        #if DEBUG
        DebugScene.defaults.bool(forKey: "CuePadActivityDiagnostics")
        #else
        false
        #endif
    }
}
