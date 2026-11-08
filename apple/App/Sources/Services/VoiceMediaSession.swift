import Foundation

nonisolated struct VoiceOffer: Equatable, Codable, Sendable { let sdp: String }
nonisolated struct VoiceAnswer: Equatable, Codable, Sendable { let sdp: String }

/// 可跨信令报告的低频生命周期事件；不包含电平、PCM 或设备凭据。
nonisolated enum VoiceMediaEvent: Equatable, Codable, Sendable {
    case connected
    case ended(reason: VoiceEndReason)
}

/// 仅本机的声音反馈，故意不遵循 Codable；UI 从本地媒体读，不能放进信令 payload。
nonisolated struct VoiceAudioLevels: Sendable {
    let input: Float
    let output: Float
}

nonisolated enum VoiceMediaClosure: Equatable, Sendable {
    case closed
    /// 清理有时限；卸载网页或取消任务本身不能冒充轨道已关闭的证据。
    case unconfirmed
}

/// 一轮一个实例，独占 WKWebView/文档/音轨/权限与 JS 等待/任务，不支持重开或重绑 session。
/// cancel 同步撤销本轮待返回操作并启动停采集；晚回来的权限、音轨、JS 和控制回调只能清理原 owner。
/// close 幂等、合并同一清理任务且有硬时限；正常、异常、取消都必须走它，不能只靠卸载网页。
/// iOS 实例由 AppServices 持有，页面导航不销毁它；后台/锁屏先 cancel 并 await close，再让既有 Relay 暂停。
/// Mac 的远端媒体适配器也实现此边界，但授权与 VoiceWire 控制只留 Mac，不交媒体实现。
@MainActor protocol VoiceMediaSession: AnyObject {
    var session: VoiceSessionID { get }
    /// 单一消费者为所属通话服务；流结束不等于音轨已清理。
    var events: AsyncStream<VoiceMediaEvent> { get }
    var onLevels: (VoiceAudioLevels) -> Void { get set }

    func offer() async throws -> VoiceOffer
    func accept(_ answer: VoiceAnswer) async throws
    func setMuted(_ muted: Bool) async throws
    func cancel()
    func close() async -> VoiceMediaClosure
}
