import Foundation

/// 同步记录与投送请求里以 JSON 文本存放的值（加密字段、请求正文）：键排好序，同样的内容同样的字节；
/// 时刻是 1970 年起的秒。读不出的（别的版本写的、格式不认识）当作没有。
protocol StoredJSON: Codable {}

extension StoredJSON {
  var stored: String { JSONColumn.encode(self) }

  init?(stored: String) {
    guard let value = JSONColumn.decode(Self.self, from: stored) else { return nil }
    self = value
  }
}

enum JSONColumn {
  static func encode(_ value: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    encoder.dateEncodingStrategy = .secondsSince1970
    return String(decoding: try! encoder.encode(value), as: UTF8.self)
  }

  /// 数组列：空的存为 NULL。
  static func encodeList(_ list: [some Encodable]) -> String? { list.isEmpty ? nil : encode(list) }

  static func decode<T: Decodable>(_ type: T.Type, from text: String?) -> T? {
    guard let text else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return try? decoder.decode(type, from: Data(text.utf8))
  }

  static func decodeList<T: Decodable>(_ type: T.Type, from text: String?) -> [T] { decode([T].self, from: text) ?? [] }
}

/// 列表里的一条：读不出（更新的版本加的种类、更早的版本存的旧形状）时为 nil，读的地方跳过它、其余照读。
struct Lenient<T: Decodable>: Decodable {
  let value: T?
  init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}
