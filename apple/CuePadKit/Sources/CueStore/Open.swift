/// 同步字段里的枚举值。其他版本的设备可能写入本版本不认识的值：读出为 `.unknown`，写回时原样保留，
/// 不当成任何已知值。本机只写已知值（写入接口收 `Known`）。
public enum Open<Known: RawRepresentable & Hashable & Sendable>: RawRepresentable, Hashable, Sendable
where Known.RawValue == String {
  case known(Known)
  case unknown(String)

  public init(rawValue: String) {
    self = Known(rawValue: rawValue).map(Self.known) ?? .unknown(rawValue)
  }

  public var rawValue: String {
    switch self {
    case .known(let value): value.rawValue
    case .unknown(let raw): raw
    }
  }

  public var known: Known? {
    if case .known(let value) = self { value } else { nil }
  }
}

extension Open: Codable {
  public init(from decoder: any Decoder) throws {
    self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}
