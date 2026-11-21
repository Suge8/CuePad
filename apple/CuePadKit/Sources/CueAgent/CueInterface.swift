public struct CueInterface: Sendable {
  public let language: String
  public let terms: [String: String]

  public init(language: String, terms: [String: String]) {
    self.language = language
    self.terms = terms
  }

  public static let chinese = CueInterface(language: "中文", terms: [:])

  var termsLine: String {
    guard !terms.isEmpty else { return "" }
    let pairs = terms.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "、")
    return "\n界面是\(language)的：提到界面上的东西照他屏幕上的叫法写（\(pairs)）。"
  }
}
