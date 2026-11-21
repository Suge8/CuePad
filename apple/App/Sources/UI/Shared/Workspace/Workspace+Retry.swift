import CueStore
import Foundation

extension Workspace {
    @discardableResult
    func retry(_ session: SessionState) -> Task<Void, Never> {
        Task {
            do { _ = try await services.retry(session) } catch { fail(error) }
        }
    }
}
