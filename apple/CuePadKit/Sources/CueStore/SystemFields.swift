import Foundation
import zlib

/// 同步元数据里每条记录的系统字段（`CKRecord.encodeSystemFields` 的归档，上传时以它为底才过得了服务器的版本校验）在库里的存法。
/// 归档每条约 2.4KB，几乎全是各条相同的键名与类名，真正因记录而异的只有记录名、版本标签与几个时刻；整条存下时一页只放得下一行，
/// 真实库 1.7 万条占了 65MB。这里用一份典型归档作 zlib 预设字典压成 raw deflate，平均约 420 字节。
/// 不带字典压缩（只省一半）、只存版本标签（`CKRecord` 没有公开的写法把它放回去）、不存而上传前先取一遍（每次改都多一次请求）都比它差。
/// `dictionary` 是库里已存数据的一部分：改了它，存下的就解不开。
enum SystemFields {
  static func pack(_ archive: Data) -> Data {
    var stream = z_stream()
    guard deflateInit2_(&stream, Z_BEST_SPEED, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
    else { preconditionFailure("deflateInit2") }
    defer { deflateEnd(&stream) }
    dictionary.withUnsafeBytes { _ = deflateSetDictionary(&stream, $0.baseAddress!.assumingMemoryBound(to: Bytef.self), uInt($0.count)) }
    var packed = Data(count: Int(deflateBound(&stream, uLong(archive.count))))
    let status = archive.withUnsafeBytes { input in
      packed.withUnsafeMutableBytes { output in
        stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress?.assumingMemoryBound(to: Bytef.self))
        stream.avail_in = uInt(input.count)
        stream.next_out = output.baseAddress!.assumingMemoryBound(to: Bytef.self)
        stream.avail_out = uInt(output.count)
        return deflate(&stream, Z_FINISH)
      }
    }
    precondition(status == Z_STREAM_END, "deflate 的输出按 deflateBound 分配，一次就写得完")
    packed.count = Int(stream.total_out)
    return packed
  }

  /// 解不开（坏数据）为 nil：调用方按没有系统字段处理，上传时作为新记录，服务器以版本冲突带回它的那一份。
  static func unpack(_ packed: Data) -> Data? {
    var stream = z_stream()
    guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
    defer { inflateEnd(&stream) }
    let set = dictionary.withUnsafeBytes { inflateSetDictionary(&stream, $0.baseAddress!.assumingMemoryBound(to: Bytef.self), uInt($0.count)) }
    guard set == Z_OK else { return nil }
    var archive = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    return packed.withUnsafeBytes { input -> Data? in
      stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress?.assumingMemoryBound(to: Bytef.self))
      stream.avail_in = uInt(input.count)
      while true {
        let (status, produced) = chunk.withUnsafeMutableBufferPointer { buffer in
          stream.next_out = buffer.baseAddress
          stream.avail_out = uInt(buffer.count)
          return (inflate(&stream, Z_NO_FLUSH), buffer.count - Int(stream.avail_out))
        }
        archive.append(contentsOf: chunk[..<produced])
        switch status {
        case Z_STREAM_END: return archive
        case Z_OK: continue
        default: return nil
        }
      }
    }
  }

  /// 一条会话消息记录的系统字段归档（记录名换成全 0）。
  private static let dictionary = Data(
    base64Encoded: """
    YnBsaXN0MDDUAQIDBAUGB2ZYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlct8QLwgJCgsMDQ4PEBESExQV
    FhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg3Ojc8OD43Nzc4ODc3NzhISTc3Nzc3Tzc3Nzg3N1Y3NzhaWzg3OF83YWI3ODdfEBZUb21ic3Rv
    bmVkUHVibGljS2V5SURzXxAZSGFzVXBkYXRlZFBhcmVudFJlZmVyZW5jZV8QE0NoYWluUHJvdGVjdGlvbkRhdGFdS25vd25Ub1NlcnZlcllCYXNlVG9rZW5f
    EBFEaXNwbGF5ZWRIb3N0bmFtZV8QEFdhbnRzQ2hhaW5QQ1NLZXlbUmVjb3JkQ3RpbWVaUm91dGluZ0tleV8QElByb3RlY3Rpb25EYXRhRXRhZ15FeHBpcmF0
    aW9uRGF0ZV8QGU1lcmdlYWJsZVZhbHVlRGVsdGFSZWNvcmRfEBpOZWVkc1JvbGxBbmRDb3VudGVyU2lnbktleV8QJlByZXZpb3VzUHJvdGVjdGlvbkRhdGFF
    dGFnRnJvbVVuaXRUZXN0XxASQ29uZmxpY3RMb3NlckV0YWdzXxAaUHJldmlvdXNQcm90ZWN0aW9uRGF0YUV0YWdfEBRIYXNVcGRhdGVkRXhwaXJhdGlvblpS
    ZWNvcmRUeXBlXxATQ3JlYXRvclVzZXJSZWNvcmRJRF8QD1BhcmVudFJlZmVyZW5jZVlTaGFyZUV0YWdYUENTS2V5SURcWm9uZWlzaEtleUlEXxAgTXV0YWJs
    ZUVuY3J5cHRlZFB1YmxpY1NoYXJpbmdLZXlURVRhZ18QFlByZXZpb3VzU2hhcmVSZWZlcmVuY2VfEBBNb2RpZmllZEJ5RGV2aWNlXlByb3RlY3Rpb25EYXRh
    XxARVXNlTGlnaHR3ZWlnaHRQQ1NeU2hhcmVSZWZlcmVuY2VfEBFVcGRhdGVkRXhwaXJhdGlvbl8QFW1vZGlmaWNhdGlvblRpbWVzdGFtcF8QFkNoYWluUGFy
    ZW50UHVibGljS2V5SURTVVJMV0V4cGlyZWRfEBhMYXN0TW9kaWZpZWRVc2VyUmVjb3JkSURbUmVjb3JkTXRpbWVfEBVXYW50c1B1YmxpY1NoYXJpbmdLZXlf
    EBZab25lUHJvdGVjdGlvbkRhdGFFdGFnWVdhc0NhY2hlZF8QEWNyZWF0aW9uVGltZXN0YW1wXxAPQ2hhaW5Qcml2YXRlS2V5WlBlcm1pc3Npb25YUmVjb3Jk
    SURcQWxsUENTS2V5SURzXxAYSGFzVXBkYXRlZFNoYXJlUmVmZXJlbmNlXxAXUHJldmlvdXNQYXJlbnRSZWZlcmVuY2WAAAiAAAmAAIAhCIAXgACAAIAACAiA
    AIAAgAAIgAGAGoAAgACAAIAAgACAIIAAgACAAAiAAIAAgBKAAIAACIAegBkIgAAIgAmAABABgAKAAAiAAK8QImdoaXBxe3x9g4aMkJSYnJ2gpKissLO2t7u+
    wcXGy8zQ0dJVJG51bGxacGlNZXNzYWdlc9Nqa2xtbm9WJGNsYXNzWlJlY29yZE5hbWVWWm9uZUlEgAiAA4AEXxAkMDAwMDAwMDAtMDAwMC0wMDAwLTAwMDAt
    MDAwMDAwMDAwMDAw1XJzdHVqdjd4eXpfEBBkYXRhYmFzZVNjb3BlS2V5XxARYW5vbnltb3VzQ0tVc2VySURZb3duZXJOYW1lWFpvbmVOYW1lEACAAIAGgAWA
    B1ZDdWVQYWRfEBBfX2RlZmF1bHRPd25lcl9f0n5/gIFaJGNsYXNzbmFtZVgkY2xhc3Nlc15DS1JlY29yZFpvbmVJRKKAglhOU09iamVjdNJ+f4SFWkNLUmVj
    b3JkSUSihILTaoeIiYqLVHRpbWVWZG9tYWlugBGADIAK0mqNjm9ccmVjb3JkWm9uZUlEgAuABNJ+f5GSXxAhQ0tTZXJ2ZXJUaW1lc3RhbXBSZWNvcmRab25l
    RG9tYWluopOCXxAhQ0tTZXJ2ZXJUaW1lc3RhbXBSZWNvcmRab25lRG9tYWlu0pVqlpdXdmVyc2lvboANgBDSapmam1l0aW1lc3RhbXCAD4AOESWN0n5/np9Z
    Q0tWZXJzaW9uop6C0n5/oaJfEBVDS1NlcnZlclRpbWVzdGFtcFRpbWWio4JfEBVDS1NlcnZlclRpbWVzdGFtcFRpbWXSfn+lpl8QEUNLU2VydmVyVGltZXN0
    YW1woqeCXxARQ0tTZXJ2ZXJUaW1lc3RhbXDTaoeIiaqrgBGAFIAT0mqtjm9ccmVjb3JkWm9uZUlEgAuABNKVarGXgBWAENJqmZq1gA+AFhIAAcnu0rhqubpX
    TlMudGltZSNByDp7K3HKwYAY0n5/vL1WTlNEYXRloryC0rhqv7ojQchAfh9D98+AGNNqa2xtw8SACIAbgBxfEBBfX2RlZmF1bHRPd25lcl9f1XJzdHVqdjd4
    yXqAAIAGgB2AB1xfZGVmYXVsdFpvbmXTamtsbc7EgAiAH4AcXxAQX19kZWZhdWx0T3duZXJfX1QyaWdlXnd3dy5pY2xvdWQuY29tAAgAEQAaACQAKQAyADcA
    SQCqAMMA3wD1AQMBDQEhATQBQAFLAWABbwGLAagB0QHmAgMCGgIlAjsCTQJXAmACbQKQApUCrgLBAtAC5ALzAwcDHwM4AzwDRANfA2sDgwOcA6YDugPMA9cD
    4APtBAgEIgQkBCUEJwQoBCoELAQtBC8EMQQzBDUENgQ3BDkEOwQ9BD4EQARCBEQERgRIBEoETAROBFAEUgRUBFUEVwRZBFsEXQRfBGAEYgRkBGUEZwRoBGoE
    bARuBHAEcgRzBHUEmgSgBKsEsgS5BMQEywTNBM8E0QT4BQMFFgUqBTQFPQU/BUEFQwVFBUcFTgVhBWYFcQV6BYkFjAWVBZoFpQWoBa8FtAW7Bb0FvwXBBcYF
    0wXVBdcF3AYABgMGJwYsBjQGNgY4Bj0GRwZJBksGTgZTBl0GYAZlBn0GgAaYBp0GsQa0BsgGzwbRBtMG1QbaBucG6QbrBvAG8gb0BvkG+wb9BwIHBwcPBxgH
    GgcfByYHKQcuBzcHOQdAB0IHRAdGB1kHZAdmB2gHagdsB3kHgAeCB4QHhgeZB54AAAAAAAACAQAAAAAAAADTAAAAAAAAAAAAAAAAAAAHrQ==
    """, options: .ignoreUnknownCharacters)!
}
