import Foundation

/// 每类独立、无服务端快照缓存的按需页。游标是原通话和稳定对象身份，不是数组位置。
nonisolated struct VoicePage<Row: Equatable & Codable & Sendable>: Equatable, Codable, Sendable {
    let items: [Row]
    let nextCursor: VoicePageCursor?
}

nonisolated enum VoicePageList: String, Codable, Sendable { case requests, replies, executions }

nonisolated enum VoicePageAnchor: Hashable, Codable, Sendable {
    case request(UUID)
    case reply(UUID)
    case execution(VoiceExecutionTarget)
}

nonisolated struct VoicePageCursor: Equatable, Codable, Sendable {
    let session: VoiceSessionID
    let list: VoicePageList
    /// nil 是明确的首页续读入口：单条放不进首页配额时，仍能用完整帧预算读取它。
    let after: VoicePageAnchor?
}

nonisolated struct VoicePageHead: Equatable, Codable, Sendable {
    var version = Data()
    var nextCursor: VoicePageCursor?
}

nonisolated struct VoicePageHeads: Equatable, Codable, Sendable {
    var requests = VoicePageHead()
    var replies = VoicePageHead()
    var executions = VoicePageHead()
}

nonisolated struct VoicePageQuery: Equatable, Codable, Sendable {
    let id: VoiceCommand.ID
    let list: VoicePageList
    let cursor: VoicePageCursor?
}

/// 页面失败不进入媒体状态机；失效游标必须由界面明确重新读首页，不能静默跳过一段历史。
nonisolated enum VoicePageError: String, Error, Codable, Sendable {
    case refreshRequired, unavailable, tooLarge, storageUnavailable
}

nonisolated struct VoicePageResult: Equatable, Codable, Sendable {
    enum Content: Equatable, Codable, Sendable {
        case requests(VoicePage<VoiceCallProjection.Request>)
        case replies(VoicePage<VoiceCallProjection.Reply>)
        case executions(VoicePage<VoiceExecutionTarget>)
        case failed(VoicePageError)
    }
    let query: VoiceCommand.ID
    let session: VoiceSessionID
    let version: Data
    let content: Content
}

nonisolated struct VoicePageSnapshot<Row: Equatable & Codable & Sendable>: Sendable {
    let page: VoicePage<Row>
    let version: Data
}
