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

  /// 这台设备当前语言的字。
  public var text: String { String(localized: value) }

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
  public var errorDescription: String? { String(localized: shown) }
}
