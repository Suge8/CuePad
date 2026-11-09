import Foundation

nonisolated struct VoiceOffer: Equatable, Codable, Sendable { let sdp: String }
nonisolated struct VoiceAnswer: Equatable, Codable, Sendable { let sdp: String }

/// 信令只携带低频生命周期；本地声音电平不进入这个类型。
nonisolated enum VoiceMediaEvent: Equatable, Codable, Sendable {
    case connected
    case ended(reason: VoiceEndReason)
}

/// 一次连接一个媒体实例，关闭后不复用。本机是原生 WebRTC（`VoicePeer`），Mac 的远端媒体适配器用同一边界；媒体永远拿不到 Codex 授权与控制通道。
protocol VoiceMedia: AnyObject {
    var supportsMute: Bool { get }
    var onEvent: (VoicePeer.Event) -> Void { get set }
    func offer() async throws -> String
    func accept(answer: String) async throws
    func setMuted(_ muted: Bool) async throws
    /// 返回时声音与连接都已停下。
    func close() async
}

extension VoiceMedia { var supportsMute: Bool { true } }
