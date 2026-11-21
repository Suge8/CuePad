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
