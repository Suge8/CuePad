#if os(macOS)
import CueAgent
import Foundation
import NaturalLanguage

extension CueInterface {
    /// 此刻界面生效的语言（与界面取字同一个选择）；界面词的叫法只在目录里，经 String(localized:) 取，和界面上的字是同一份。
    static var current: CueInterface {
        let code = Bundle.main.preferredLocalizations.first ?? "zh-Hans"
        guard !code.hasPrefix("zh") else { return .chinese }
        return CueInterface(language: Self.name(of: code), terms: [
            "灵感": String(localized: "灵感"), "任务": String(localized: "任务"), "子任务": String(localized: "子任务"),
            "正文": String(localized: "正文"), "项目": String(localized: "项目"), "默认": String(localized: "默认"),
            "置顶": String(localized: "置顶"), "归档": String(localized: "归档"), "回收站": String(localized: "回收站"),
            "进展": String(localized: "进展"), "看板": String(localized: "看板"), "会话": String(localized: "会话"),
            "推进中": String(localized: "推进中"), "等你": String(localized: "等你"), "待回复": String(localized: "待回复"),
            "记忆": String(localized: "记忆"), "已完成": String(localized: "已完成"),
        ])
    }

    /// 这一轮 Cue 写下的字用什么语言（`CueEnvelope.Input.language`）：他这句话的语言，他没开口或认不出时用界面语言；中文为 nil。
    func writing(after said: String?) -> String? {
        let code = said.flatMap { NLLanguageRecognizer.dominantLanguage(for: $0)?.rawValue } ?? (terms.isEmpty ? "zh" : nil)
        guard let code else { return language }
        return code.hasPrefix("zh") ? nil : Self.name(of: code)
    }

    private static func name(of code: String) -> String {
        Locale(identifier: "zh-Hans").localizedString(forIdentifier: code) ?? code
    }
}
#endif
