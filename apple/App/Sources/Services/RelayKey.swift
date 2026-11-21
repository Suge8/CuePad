import CryptoKit
import Foundation

struct RelayCredentials: Sendable {
    static let context = "cuepad-relay-v1"
    let room: String
    private let key: Curve25519.Signing.PrivateKey
    let voiceKey: SymmetricKey
    let tunnelKey: SymmetricKey

    init(secret: Data) throws {
        let seed = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret), info: Data("\(Self.context) signing".utf8), outputByteCount: 32)
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed.withUnsafeBytes { Data($0) })
        room = key.publicKey.rawRepresentation.base64URL
        voiceKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
                                        info: Data(VoiceSignalFormat.keyContext.utf8), outputByteCount: 32)
        tunnelKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), info: Data(LiveTunnel.keyContext.utf8), outputByteCount: 32)
    }

    func signVoice(_ claim: VoiceRegistrationClaim) throws -> Data {
        guard claim.room == room else { throw VoiceSignalError.invalid }
        return try key.signature(for: claim.signatureInput())
    }

    func sign(_ nonce: String) throws -> String {
        try key.signature(for: Data("\(Self.context)\n\(room)\n\(nonce)".utf8)).base64URL
    }
}

enum RelayError: LocalizedError {
    case unexpectedFrame
    case handshakeTimeout
    case silent

    var errorDescription: String? {
        switch self {
        case .unexpectedFrame: "中转没按协议回"
        case .handshakeTimeout: "没在时限内连上、入房"
        case .silent: "心跳没有回应"
        }
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
    }
}
