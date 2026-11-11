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

/// 页面失败不进入媒体状态机；原通话不可读与同通话锚点失效必须区分，不能静默改绑另一通话。
nonisolated enum VoicePageError: String, Error, Codable, Sendable {
    /// 同一通话的锚点失效，明确重新读取首页。
    case refreshRequired
    /// 原通话已替换或不存在；首页重试也不能恢复。到 Mac 查看当前通话/恢复保留请求，不自动改绑旧动作。
    case sessionUnavailable
    case unavailable, tooLarge, storageUnavailable
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
