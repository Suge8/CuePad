#if DEBUG && os(macOS)
import CryptoKit
import Foundation

/// 只用固定公开样例密钥产生互操作材料，不读取本机授权或资料，不建立连接。
extension DebugSplitAudit {
    static func wireFixture() throws {
        let secret = Data(0..<32)
        let seed = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
                                        info: Data("cuepad-relay-v1 signing".utf8), outputByteCount: 32)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed.withUnsafeBytes { Data($0) })
        let room = key.publicKey.rawRepresentation.base64EncodedString().replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
        let sender = VoiceEndpoint(device: .init("iphone-probe"), lease: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
        let recipient = VoiceEndpoint(device: .init("mac-probe"), lease: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!)
        let session = VoiceSessionID(UUID(uuidString: "33333333-3333-4333-8333-333333333333")!)
        let request = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let claim = VoiceRegistrationClaim(version: VoiceSignalFormat.version, room: room,
                                           challenge: Data(repeating: 42, count: 32).base64EncodedString().replacing("=", with: ""), device: sender.device)
        let proof = try claim.signatureInput()
        let signature = try key.signature(for: proof)
        let header = VoiceSignalHeader(version: VoiceSignalFormat.version, sender: sender, recipient: recipient,
                                       session: session, sequence: 1, expiresAtMilliseconds: 1_794_114_330_000)
        let plaintext = try VoiceSignalFormat.canonicalJSON(VoiceSignalPayload.media(signal: .hangup(reason: .hungUp)))
        let signalKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
                                             info: Data(VoiceSignalFormat.keyContext.utf8), outputByteCount: 32)
        let nonce = try AES.GCM.Nonce(data: Data(repeating: 7, count: 12))
        let box = try AES.GCM.seal(plaintext, using: signalKey, nonce: nonce, authenticating: header.authenticationData())
        guard let combined = box.combined else { throw DebugSplitVoice.ProbeError.invalid }
        let packet = VoiceSealedSignal(header: header, sealed: combined)
        func frame<T: Encodable>(_ value: T) throws -> [String: Any] {
            ["t": "voice", "body": try JSONSerialization.jsonObject(with: VoiceSignalFormat.canonicalJSON(value))]
        }
        let result: [String: Any] = [
            "testOnly": true, "sampleSecretHex": secret.map { String(format: "%02x", $0) }.joined(),
            "registrationSignedUTF8": String(decoding: proof, as: UTF8.self), "aadUTF8": String(decoding: try header.authenticationData(), as: UTF8.self),
            "plaintextUTF8": String(decoding: plaintext, as: UTF8.self),
            "ready": ["t": "ready", "voiceVersion": 1],
            "register": try frame(VoiceRelayRequest.register(claim: claim, signature: signature)),
            "registered": try frame(VoiceRelayResponse.registered(endpoint: sender)),
            "resolve": try frame(VoiceRelayRequest.resolve(request: request, device: recipient.device)),
            "resolved": try frame(VoiceRelayResponse.resolved(request: request, endpoint: recipient)),
            "unavailable": try frame(VoiceRelayResponse.unavailable(request: request, device: recipient.device)),
            "send": try frame(VoiceRelayRequest.signal(packet: packet)),
            "receive": try frame(VoiceRelayResponse.signal(packet: packet)),
            "departed": try frame(VoiceRelayResponse.departed(endpoint: sender, reason: .disconnected)),
            "replaced": try frame(VoiceRelayResponse.departed(endpoint: sender, reason: .replaced)),
            "rejected": try frame(VoiceRelayResponse.rejected(header: header, reason: .leaseMismatch)),
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: URL(filePath: "/tmp/voice89-wire-fixture.json"))
        DebugSplitVoice.note("wire-fixture-written")
    }
}
#endif
