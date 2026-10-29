import CueStore
import Foundation

extension AppServices {
    /// 回答 Cue 的一件拍板：选一项（不选的话在 Cue 页直接说，见 `CueQuestionEnd`）。Cue 页的卡与实时活动的"允许一次"（`AllowOnceIntent`，可能没有窗口）同走这里。
    /// 选"以后……不用问"时 Store 同时把这句原话记成一条一直记着的记忆，一起上传。
    func answerCueQuestion(_ message: UUID, _ choice: String) async throws {
        let noted = try await store.endCueQuestion(message, .answered(choice))
        #if os(iOS)
        await resendSnapshots()
        #endif
        await sync?.upload([message] + [noted].compactMap { $0 })
    }
}
