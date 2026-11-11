import Foundation

/// 首页在 phoneVoice 的三类 page；after=nil 明确刷新首页，nextCursor 读取下一页。
/// 服务持有每类当前展示页；不要把返回值再无限追加到第二套列表。UI 只读取 page/loading/error。
/// 请求和朗读按稳定身份整页替换；执行内容变化立即撤下旧目标，刷新原页。refreshRequired 要显式回首页。
/// 媒体挂断不关闭这些只读入口；sessionUnavailable 表示原通话已替换/不存在，不能再承诺首页重试。
/// 此时保留已有请求/朗读摘要并撤下停止目标和翻页入口，指引到 Mac 查看当前通话或恢复保留请求，不自动开通话、改绑 session 或旧动作；动作始终传原 reference/target。
extension Workspace {
    @discardableResult
    func loadVoiceRequests(after cursor: VoicePageCursor? = nil) async throws -> VoicePage<VoiceCallProjection.Request> {
        try await services.voice.loadRequests(after: cursor)
    }

    @discardableResult
    func loadVoiceReplies(after cursor: VoicePageCursor? = nil) async throws -> VoicePage<VoiceCallProjection.Reply> {
        try await services.voice.loadReplies(after: cursor)
    }

    @discardableResult
    func loadVoiceExecutions(after cursor: VoicePageCursor? = nil) async throws -> VoicePage<VoiceExecutionTarget> {
        try await services.voice.loadExecutions(after: cursor)
    }
}
