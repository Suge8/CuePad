import CryptoKit
import Foundation

/// 由名字得到确定的 UUID（v5，固定命名空间）：导入的旧行、按会话唯一的记录，在任何设备上得到同一个 id。
enum DeterministicID {
  private static let namespace: [UInt8] = [
    0x6c, 0x9a, 0x4d, 0x1e, 0x0b, 0x53, 0x4f, 0x8a, 0x9e, 0x27, 0xc1, 0x3d, 0x5a, 0x70, 0x84, 0xb2,
  ]

  static func uuid(_ name: String) -> UUID {
    var hash = Array(Insecure.SHA1.hash(data: Data(namespace + Array(name.utf8))))
    hash[6] = (hash[6] & 0x0f) | 0x50
    hash[8] = (hash[8] & 0x3f) | 0x80
    return UUID(uuid: (
      hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
      hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]
    ))
  }
}
