#if os(macOS)
import CueStore
import Foundation
// 临时：合并 feat/leaf-model 后删除
extension CueStore {
    func bindSession(_ sessionID: String, to task: UUID) async throws -> String? { nil }
}
#endif
