// 自己的 EdDSA（Ed25519）密钥，格式与 Sparkle 的 --ed-key-file 兼容：私钥文件内容是 32 字节种子的 base64。
// swift sparkle-key.swift generate        → 标准输出两行：种子(base64)、公钥(base64)
// swift sparkle-key.swift public          → 从标准输入读种子，输出公钥
import CryptoKit
import Foundation

switch CommandLine.arguments.dropFirst().first {
case "generate":
    let key = Curve25519.Signing.PrivateKey()
    print(key.rawRepresentation.base64EncodedString())
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    let seed = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw = Data(base64Encoded: seed), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        FileHandle.standardError.write(Data("不是有效的种子\n".utf8)); exit(1)
    }
    print(key.publicKey.rawRepresentation.base64EncodedString())
default:
    FileHandle.standardError.write(Data("用法：sparkle-key.swift <generate|public>\n".utf8)); exit(2)
}
