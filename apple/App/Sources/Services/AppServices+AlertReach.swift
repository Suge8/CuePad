import CueStore
import Foundation

extension AppServices {
    /// 这条提示此刻到不到你（`CueStore.reaches`）；读不出就照常提示，宁可多响一次也不悄悄吞掉。
    func reaches(_ subject: AlertSubject) async -> Bool {
        do {
            return try await store.reaches(subject)
        } catch {
            Self.log.error("没能读出这条提示到不到你，照常提示：\(error.localizedDescription, privacy: .public)")
            return true
        }
    }
}
