#if DEBUG

/// 手机端通话面板的参数。
/// 键 = `-CuePad` + 前缀「PhoneVoice」 + 字段名（大小写不论）；没给：Bool 为 false、数为 0、可选为 nil。
nonisolated struct PhoneVoiceArgs: Decodable, DebugArgGroup {
    static let prefix = "PhoneVoice"
    /// `-CuePadPhoneVoiceEnabled YES`：手机通话开关打开
    let enabled: Bool
    /// `-CuePadPhoneVoiceDetails YES`：摆好后打开通话详情（没有落点、居中）
    let details: Bool
    /// `-CuePadPhoneVoiceHistory <条数>`：通话历史条数
    let history: Int
    /// `-CuePadPhoneVoiceReplay interactive|normal|rapid|cycle|reverse`：隔离回放通话
    let replay: String?
}
#endif
