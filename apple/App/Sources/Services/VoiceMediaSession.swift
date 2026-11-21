import Foundation

nonisolated struct VoiceOffer: Equatable, Codable, Sendable {
    let sdp: String
    var version = VoiceSignalFormat.callVersion
}
nonisolated struct VoiceAnswer: Equatable, Codable, Sendable {
    let sdp: String
    var version = VoiceSignalFormat.callVersion
}

nonisolated enum VoiceMediaEvent: Equatable, Codable, Sendable {
    case connected
    case ended(reason: VoiceEndReason)
}

protocol VoiceMedia: AnyObject {
    var supportsMute: Bool { get }
    var onEvent: (VoicePeer.Event) -> Void { get set }
    func offer() async throws -> String
    func accept(answer: String) async throws
    func setMuted(_ muted: Bool) async throws
    func close() async
}

extension VoiceMedia { var supportsMute: Bool { true } }
