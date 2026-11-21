#if DEBUG
import Foundation

extension Task where Success == Never, Failure == Never {
    @discardableResult
    static func wait(for duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return true
        } catch {
            return false
        }
    }
}
#endif
