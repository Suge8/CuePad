import Foundation

/// 一台设备写下、同步给各端、各端按自己的语言显示的界面字（投送没送到的原因、Agent 不能用的原因、CuePad 替 Cue 写下的话）：
/// 存的是目录里的键与参数（`String.LocalizationValue` 的 JSON，与写下它的设备、语言无关），读的设备取自己语言的字（`text`）。
/// 参数照写下时的原样：名字、Agent 与提供方的原文报错；没有句式的原文用 `verbatim`，各端原样显示。
/// 不用 `LocalizedStringResource`：它的 JSON 带着写下那台设备的语言、App 路径与沙盒令牌，换台设备取不了字。
public struct ShownText: Equatable, Sendable, StoredJSON {
  public let value: String.LocalizationValue

  public init(_ value: String.LocalizationValue) { self.value = value }

  /// 错误的说法：能交给别的设备按它的语言显示的（`ShownError`）存句式与参数，别的（系统、第三方的错误）存这台的原文。
  public init(_ error: any Error) {
    self = (error as? any ShownError).map { ShownText($0.shown) } ?? .verbatim(error.localizedDescription)
  }

  /// 原文（不进目录、各端照写下的显示）。
  public static func verbatim(_ text: String) -> ShownText {
    var words = String.LocalizationValue.StringInterpolation(literalCapacity: 0, interpolationCount: 1)
    words.appendInterpolation(text)
    return ShownText(String.LocalizationValue(stringInterpolation: words))
  }

  /// 这台设备当前语言的字：嵌着的话（`embedded`）先各按这台的语言取字，再填进句式。
  public var text: String {
    guard var words = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any],
      let arguments = words["arguments"] as? [[String: Any]],
      arguments.contains(where: { Self.nested(in: $0) != nil })
    else { return String(localized: value) }
    words["arguments"] = arguments.map { argument in Self.nested(in: argument).map { ["string": ["_0": $0.text]] } ?? argument }
    guard let data = try? JSONSerialization.data(withJSONObject: words),
      let resolved = try? JSONDecoder().decode(String.LocalizationValue.self, from: data)
    else { return String(localized: value) }
    return String(localized: resolved)
  }

  /// 嵌进另一句里的写法（`ShownText("我起不来了：\(reason.embedded)")`）：句式的参数里只能放字，这一句整个编成一个带记号的字，
  /// 读的时候（`text`）认出来，按读的设备的语言取字。只用作 `ShownText` 句式里的参数，不直接显示。
  public var embedded: String { Self.embeddedMark + stored }

  /// 嵌着的那句的记号：对象替换符开头，不会出现在原文的开头。
  private static let embeddedMark = "\u{FFFC}shown:"

  /// 句式的一个参数（`String.LocalizationValue` 的 JSON 形状：字是 `{"string": {"_0": …}}`）若是嵌着的一句，取出来。
  private static func nested(in argument: [String: Any]) -> ShownText? {
    guard let words = (argument["string"] as? [String: Any])?["_0"] as? String, words.hasPrefix(embeddedMark) else { return nil }
    return ShownText(stored: String(words.dropFirst(embeddedMark.count)))
  }

  public init(from decoder: any Decoder) throws { value = try decoder.singleValueContainer().decode(String.LocalizationValue.self) }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value)
  }
}

/// 说法要交给别的设备按它的语言显示的错误（写进同步记录的，见 `ShownText`）：`shown` 是唯一的说法，`errorDescription` 由它取这台的字。
public protocol ShownError: LocalizedError {
  var shown: String.LocalizationValue { get }
}

extension ShownError {
  public var errorDescription: String? { ShownText(shown).text }
}
