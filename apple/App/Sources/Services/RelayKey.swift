import CloudKit
import CryptoKit
import CueStore
import CueSync
import Foundation

/// 门铃的密钥：只在你自己的 iCloud 里——私有库单独一个区里的一条记录（`RelaySecretRecord`），值在加密字段里，Apple 与中转都读不到。
/// 第一台要用门铃的设备生成 32 字节随机数存进去；两台同时生成时以先存进去的为准（不覆盖已有的那条，被拒就用服务器上的）。
///
/// 没选 iCloud 钥匙串：它另有开关，关着的设备拿不到；同步时机不定、同时生成的两台没有先来后到可认，会各进各的房间；
/// Mac 还要另加钥匙串权限。放在 CloudKit 里，能同步的设备就拿得到同一把，换账号自然换钥匙。
enum RelayKey {
    static let zoneID = CKRecordZone.ID(zoneName: RelaySecretRecord.zoneName, ownerName: CKCurrentUserDefaultName)
    static let recordID = CKRecord.ID(recordName: RelaySecretRecord.recordName, zoneID: zoneID)
    static let length = 32

    /// 每次连中转前取一次（不缓存：换了 iCloud 账号下一次连就进新账号的房间）。
    static func credentials(in database: CKDatabase) async throws -> RelayCredentials {
        try RelayCredentials(secret: try await secret(in: database))
    }

    private static func secret(in database: CKDatabase) async throws -> Data {
        do {
            return try value(of: try await database.record(for: recordID))
        } catch let error as CKError where error.code == .unknownItem {
            return try await create(in: database)
        } catch let error as CKError where error.code == .zoneNotFound {
            _ = try await database.save(CKRecordZone(zoneID: zoneID))
            return try await create(in: database)
        }
    }

    private static func create(in database: CKDatabase) async throws -> Data {
        let record = CKRecord(recordType: RelaySecretRecord.recordType, recordID: recordID)
        record.encryptedValues[RelaySecretRecord.field] = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let (saved, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
        switch saved[recordID] {
        case .success(let record): return try value(of: record)
        case .failure(let error as CKError) where error.code == .serverRecordChanged:
            guard let server = error.serverRecord else { throw error }
            return try value(of: server)
        case .failure(let error): throw error
        case nil: throw RelayError.malformedSecret
        }
    }

    private static func value(of record: CKRecord) throws -> Data {
        guard let secret = record.encryptedValues[RelaySecretRecord.field] as? Data, secret.count == length else { throw RelayError.malformedSecret }
        return secret
    }
}

/// 中转看到的只有由密钥派生的这两样：房间号（Ed25519 公钥）与对它出的随机数的签名。协议见 `relay/server.ts` 的头注释。
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

enum RelayError: Error {
    case malformedSecret
    /// 中转没按协议回（握手的帧不对、超时）。
    case unexpectedFrame
    /// `Relay.handshakeLimit` 内没连上、入房。
    case handshakeTimeout
    /// 心跳没有回应。
    case silent
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
    }
}
