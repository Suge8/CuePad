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
        let code = said.flatMap(Self.language(of:)) ?? (terms.isEmpty ? "zh" : nil)
        guard let code else { return language }
        return code.hasPrefix("zh") ? nil : Self.name(of: code)
    }

    /// 一句话的语言代码，说不准为 nil（用界面语言）。识别器常把夹着英文词的中文认成别的语言（实测"用 Claude Code 修 bug"认成英文，
    /// 夹着项目名与文件名的一句认成加泰罗尼亚语），短句也乱认（"ok"认成波兰语、"hi"认成加泰罗尼亚语），Cue 就用那种语言回他。
    /// 有汉字、没有假名时：汉字不少于英文词按中文算，英文词更多的说不准；其余要识别器有把握（`confident`）才算。
    private static func language(of text: String) -> String? {
        let scalars = text.unicodeScalars
        let han = scalars.count { $0.properties.isIdeographic }
        if han > 0, !scalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) {
            return han >= text.matches(of: /[A-Za-z]+/).count ? "zh" : nil
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, probability) = recognizer.languageHypotheses(withMaximum: 1).first, probability >= confident else { return nil }
        return language.rawValue
    }

    /// 识别器的把握：实测"yes"（0.90）、"fix the login bug"（0.86）够，"hi"（0.80，认成加泰罗尼亚语）与"ok"（0.29，认成波兰语）不够。
    private static let confident = 0.85

    private static func name(of code: String) -> String {
        Locale(identifier: "zh-Hans").localizedString(forIdentifier: code) ?? code
    }
}
#endif
