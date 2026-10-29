import Foundation
#if os(iOS)
import ActivityKit
import AppIntents
#endif

/// 实时活动只传 Cue 此刻，保留 now 信封；远程由 Mac 推出，本地演示由 App 推出，小组件进程只画。
nonisolated struct CueActivityState: Codable, Hashable, Sendable {
    var now: CueNow

    func same(as other: CueActivityState) -> Bool { now.same(as: other.now) }
}

#if os(iOS)
nonisolated struct CueActivityAttributes: ActivityAttributes {
    typealias ContentState = CueActivityState
    /// 推送地址的原始到期起点，不随内容或令牌更新续期；缺少元数据的活动不注册远程地址。
    var startedAt: Date? = .now
    var remoteUpdates: Bool?
}

/// 实时活动上的"允许一次"：在 App 进程里执行（`LiveActivityIntent`，不打开 App），走 Cue 页回答提问的同一个方法。
/// 谁来答由 App 启动时交给 App Intents（`AppDependencyManager`，`IOSAppDelegate`）；小组件进程里只有这个类型、不执行它。
struct AllowOnceIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "允许一次"
    static let isDiscoverable = false

    @Parameter(title: "提问") var message: String
    @Parameter(title: "选项") var choice: String
    @Dependency private var answerer: any CueQuestionAnswering

    init() {}

    init(_ allow: CueNow.Allow) {
        message = allow.message.uuidString
        choice = allow.choice
    }

    @MainActor func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: message) else { return .result() }
        try await answerer.answerCueQuestion(id, choice)
        return .result()
    }
}

/// 回答 Cue 的一条提问（选第几项由调用方给）。
@MainActor protocol CueQuestionAnswering: Sendable {
    func answerCueQuestion(_ message: UUID, _ choice: String) async throws
}
#endif
