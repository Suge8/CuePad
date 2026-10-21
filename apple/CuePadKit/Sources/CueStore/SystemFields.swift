import Foundation

/// 同步元数据里每条记录的系统字段（`CKRecord.encodeSystemFields` 的归档，上传时以它为底才过得了服务器的版本校验）在库里的存法。
/// 归档每条约 2.4KB，几乎全是各条相同的键名、类名与结构，因记录而异的只有记录名、版本标签与几个时刻；整条存下时一页只放得下一行，
/// 真实库 1.7 万条占了 65MB。这里只对一份典型归档（`dictionary`）做匹配：与它相同的片段记成（位置、长度），其余原样，平均约 460 字节。
/// 格式是一串"字面长度、字面字节、字典位置、匹配长度"，以最后一段字面结束，长度与位置都是 LEB128 变长整数。
/// 不用 zlib 预设字典（约 420 字节）：deflate 每条约 20 万条指令，升级时 1.7 万条要多花半秒；这里压一条约 2.3 万条、解约 1.6 万条。
/// 只存版本标签不行（`CKRecord` 没有公开的写法把它放回去），不存而上传前先取一遍每次改都多一次请求。
/// `dictionary` 是库里已存数据的一部分：改了它，存下的就解不开。
enum SystemFields {
  static func pack(_ archive: Data) -> Data {
    Data(archive.withUnsafeBytes(pack))
  }

  static func pack(_ input: UnsafeRawBufferPointer) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(input.count / 4)
    let count = input.count
    dictionary.withUnsafeBytes { dictionary in
      starts.withUnsafeBufferPointer { starts in
        var at = 0, literal = 0
        while at + 4 <= count {
          let key = input.loadUnaligned(fromByteOffset: at, as: UInt32.self)
          let start = Int(starts[slot(key)]) - 1
          guard start >= 0, dictionary.loadUnaligned(fromByteOffset: start, as: UInt32.self) == key else {
            at += 1
            continue
          }
          var length = 4
          while start + length + 8 <= dictionary.count, at + length + 8 <= count {
            let difference = dictionary.loadUnaligned(fromByteOffset: start + length, as: UInt64.self)
              ^ input.loadUnaligned(fromByteOffset: at + length, as: UInt64.self)
            guard difference == 0 else { break }
            length += 8
          }
          while start + length < dictionary.count, at + length < count, dictionary[start + length] == input[at + length] { length += 1 }
          append(at - literal, to: &out)
          out.append(contentsOf: input[literal..<at])
          append(start, to: &out)
          append(length, to: &out)
          at += length
          literal = at
        }
        append(count - literal, to: &out)
        out.append(contentsOf: input[literal..<count])
      }
    }
    return out
  }

  /// 解不开（坏数据）为 nil：调用方按没有系统字段处理，上传时作为新记录，服务器以版本冲突带回它的那一份。
  static func unpack(_ packed: Data) -> Data? {
    packed.withUnsafeBytes { input in
      dictionary.withUnsafeBufferPointer { dictionary -> Data? in
        var out: [UInt8] = []
        out.reserveCapacity(dictionary.count + 256)
        var at = 0
        while true {
          guard let literal = read(input, &at), literal <= input.count - at else { return nil }
          out.append(contentsOf: input[at..<at + literal])
          at += literal
          if at == input.count { return Data(out) }
          guard let start = read(input, &at), let length = read(input, &at), start <= dictionary.count - length else { return nil }
          out.append(contentsOf: dictionary[start..<start + length])
        }
      }
    }
  }

  private static func append(_ value: Int, to out: inout [UInt8]) {
    var value = UInt(value)
    while value >= 0x80 {
      out.append(UInt8(truncatingIfNeeded: value) | 0x80)
      value >>= 7
    }
    out.append(UInt8(value))
  }

  private static func read(_ input: UnsafeRawBufferPointer, _ at: inout Int) -> Int? {
    var value = 0, shift = 0
    while at < input.count, shift < 35 {
      let byte = input[at]
      at += 1
      value |= Int(byte & 0x7F) << shift
      if byte < 0x80 { return value }
      shift += 7
    }
    return nil
  }

  private static func slot(_ key: UInt32) -> Int { Int((key &* 2_654_435_761) >> 20) }

  /// 字典里每个 4 字节片段第一次出现的位置（加 1，0 是没有），按片段的散列放。
  private static let starts: [UInt16] = {
    var starts = [UInt16](repeating: 0, count: 1 << 12)
    dictionary.withUnsafeBytes { dictionary in
      for start in stride(from: dictionary.count - 4, through: 0, by: -1) {
        starts[slot(dictionary.loadUnaligned(fromByteOffset: start, as: UInt32.self))] = UInt16(start + 1)
      }
    }
    return starts
  }()

  /// 一条会话消息记录的系统字段归档（记录名换成全 0）。
  private static let dictionary = [UInt8](
    Data(
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
    """, options: .ignoreUnknownCharacters)!)
}
