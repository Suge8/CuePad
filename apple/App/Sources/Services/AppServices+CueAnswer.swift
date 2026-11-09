import CueStore
import Foundation

extension AppServices {
    /// 远程活动的提问可能还没入本机库，也可能已被撤回：先等真实的一拉，不走界面的五秒忙碌时限、不以全局同步状态代替结果。
    /// 普通 App 内作答不经这里，已有本地提问的离线回答仍照常排队上传。
    func answerRemoteCueQuestion(_ message: UUID, _ choice: String) async throws {
        guard let sync, try await sync.syncNow() != .incomplete else { throw URLError(.cannotLoadFromNetwork) }
        try Task.checkCancellation()
        try await answerCueQuestion(message, choice)
    }

    /// 选"以后……不用问"时 Store 同时把这句原话记成一条重点记忆，一起上传。
    func answerCueQuestion(_ message: UUID, _ choice: String) async throws {
        let noted = try await store.endCueQuestion(message, .answered(choice))
        #if os(iOS)
        await resendSnapshots()
        #endif
        await sync?.upload([message] + [noted].compactMap { $0 })
    }
}
