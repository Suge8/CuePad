import Foundation

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

  static func encodeList(_ list: [some Encodable]) -> String? { list.isEmpty ? nil : encode(list) }

  static func decode<T: Decodable>(_ type: T.Type, from text: String?) -> T? {
    guard let text else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return try? decoder.decode(type, from: Data(text.utf8))
  }

  static func decodeList<T: Decodable>(_ type: T.Type, from text: String?) -> [T] { decode([T].self, from: text) ?? [] }
}

struct Lenient<T: Decodable>: Decodable {
  let value: T?
  init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}
