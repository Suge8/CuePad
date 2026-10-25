import CryptoKit
import Foundation

/// 中转看到的只有由门铃的密钥（`CloudSync.relaySecret`）派生的这两样：房间号（Ed25519 公钥）与对它出的随机数的签名。协议见 `relay/server.ts` 的头注释。
struct RelayCredentials: Sendable {
    static let context = "cuepad-relay-v1"
    let room: String
    private let key: Curve25519.Signing.PrivateKey

    init(secret: Data) throws {
        let seed = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret), info: Data("\(Self.context) signing".utf8), outputByteCount: 32)
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed.withUnsafeBytes { Data($0) })
        room = key.publicKey.rawRepresentation.base64URL
    }

    func sign(_ nonce: String) throws -> String {
        try key.signature(for: Data("\(Self.context)\n\(room)\n\(nonce)".utf8)).base64URL
    }
}

enum RelayError: LocalizedError {
    /// 中转没按协议回（握手的帧不对）。
    case unexpectedFrame
    /// `Relay.handshakeLimit` 内没连上、入房。
    case handshakeTimeout
    /// 心跳没有回应。
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
