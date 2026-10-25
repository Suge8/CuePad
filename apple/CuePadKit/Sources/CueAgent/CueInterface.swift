/// 他屏幕上的界面用什么语言（App 按当前生效的本地化给，`CuePrompt.system` 用）：Cue 跟他说话的语言走，他还没开口时用这个。
/// 界面不是中文时 `terms` 是界面词在他屏幕上的叫法（键是系统提示里的中文叫法），Cue 提到它们时和他看到的字对得上。
public struct CueInterface: Sendable {
  public let language: String
  public let terms: [String: String]

  public init(language: String, terms: [String: String]) {
    self.language = language
    self.terms = terms
  }

  /// 中文界面：系统提示里的叫法就是界面上的。
  public static let chinese = CueInterface(language: "中文", terms: [:])

  var termsLine: String {
    guard !terms.isEmpty else { return "" }
    let pairs = terms.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "、")
    return "\n界面是\(language)的：提到界面上的东西照他屏幕上的叫法写（\(pairs)）。"
  }
}
