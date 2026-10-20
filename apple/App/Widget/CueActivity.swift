import Foundation
#if os(iOS)
import ActivityKit
import AppIntents
#endif

/// 实时活动的一份（iPhone 锁屏与灵动岛；macOS 26 起系统把它转进 Mac 的菜单栏，Mac 不写代码）：Cue 的表情、在管与等你的数、一排格子、
/// 第一件等你与锁屏最下一行最近做完的。App 由库推出（`CueActivityState.read`，数只读 `CueStore.cueTally`），小组件进程只画（`CueActivityViews`）。
nonisolated struct CueActivityState: Codable, Hashable, Sendable {
    /// 头像的表情（`CueMood` 的原始值，图在 CueFaces 里）。
    var mood: String
    var managing: Int
    var waiting: Int
    /// 今天做完的顶层任务几件（格子里的石绿）。
    var done: Int
    var first: Wait?
    var lastDone: Done?
    /// 这一份是什么时候写下的：过时（`staleDate`）后卡片变淡，写"x 分钟前"。
    var at: Date

    /// 第一件等你：说什么、"打开"去哪，只有 Cue 带选项的提问能"允许一次"（会话在问的只给打开）。
    struct Wait: Codable, Hashable, Sendable {
        var title: String
        var detail: String?
        var open: URL
        var allow: Allow?
    }

    /// "允许一次"答哪条提问、选哪一项（提问的第一项，`CueAsk.once`）。
    struct Allow: Codable, Hashable, Sendable {
        var message: UUID
        var choice: String
    }

    struct Done: Codable, Hashable, Sendable {
        var title: String
        var at: Date
    }

    enum Cell: String, Codable, Sendable {
        case managing, waiting, done
    }

    static let cellLimit = 8

    /// 格子：每件在管、每件等你、今天做完的各一格，按这个先后排；放不下 `cellLimit` 格时先保等你、再保在管，做完的最先让出去。
    var cells: [Cell] {
        let waits = min(waiting, Self.cellLimit)
        let manages = min(managing, Self.cellLimit - waits)
        let dones = min(done, Self.cellLimit - waits - manages)
        return Array(repeating: .managing, count: manages) + Array(repeating: .waiting, count: waits) + Array(repeating: .done, count: dones)
    }

    /// 有在管或等你的才开着实时活动，都没了就结束。
    var isLive: Bool { managing > 0 || waiting > 0 }

    /// 内容一样（不看写下的时刻）：一样的就不重发。
    func same(as other: CueActivityState) -> Bool {
        var other = other
        other.at = at
        return self == other
    }
}

#if os(iOS)
nonisolated struct CueActivityAttributes: ActivityAttributes {
    typealias ContentState = CueActivityState
}

/// 实时活动上的"允许一次"：在 App 进程里执行（`LiveActivityIntent`，不打开 App），走 Cue 页回答提问的同一个方法（`CueActivityAnswer`）。
/// 小组件进程里只有这个类型、不执行它。
struct AllowOnceIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "允许一次"
    static let isDiscoverable = false

    @Parameter(title: "提问") var message: String
    @Parameter(title: "选项") var choice: String

    init() {}

    init(_ allow: CueActivityState.Allow) {
        message = allow.message.uuidString
        choice = allow.choice
    }

    @MainActor func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: message), let answer = CueActivityAnswer.answer else { throw CueActivityAnswer.Unavailable() }
        try await answer(id, choice)
        return .result()
    }
}

/// App 进程里谁来答：资料库与服务建好时登记（`IOSAppDelegate`），打不开库时为 nil。
enum CueActivityAnswer {
    static var answer: (@MainActor (UUID, String) async throws -> Void)?

    struct Unavailable: Error, CustomLocalizedStringResourceConvertible {
        var localizedStringResource: LocalizedStringResource { "CuePad 的资料库没打开，到 App 里看看" }
    }
}
#endif
