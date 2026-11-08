import Foundation

nonisolated struct VoiceOffer: Equatable, Codable, Sendable { let sdp: String }
nonisolated struct VoiceAnswer: Equatable, Codable, Sendable { let sdp: String }

/// 信令只携带低频生命周期；本地声音电平不进入这个类型。
nonisolated enum VoiceMediaEvent: Equatable, Codable, Sendable {
    case connected
    case ended(reason: VoiceEndReason)
}

/// 一次连接一个媒体实例，关闭先同步撤销权限/JS/发送等待，再有界地清理轨道与上下文，不靠卸载网页冒充成功。
/// 本机使用系统 WebKit，Mac 的远端媒体适配器使用同一边界；媒体永远拿不到 Codex 授权与控制通道。
protocol VoiceMedia: AnyObject {
    var onEvent: (VoicePeer.Event) -> Void { get set }
    func offer() async throws -> String
    func accept(answer: String) async throws
    func play() async throws
    func setMuted(_ muted: Bool) async throws
    func close() async throws
}
