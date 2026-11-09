#if DEBUG

/// 手机端通话面板的参数。
/// 键 = `-CuePad` + 前缀「PhoneVoice」 + 字段名（大小写不论）；没给：Bool 为 false、数为 0、可选为 nil。
nonisolated struct PhoneVoiceArgs: Decodable, DebugArgGroup {
    static let prefix = "PhoneVoice"
    /// `-CuePadPhoneVoiceEnabled YES`：手机通话开关打开
    let enabled: Bool
    /// `-CuePadPhoneVoiceHistory <条数>`：通话历史条数
    let history: Int
    /// `-CuePadPhoneVoiceLastPage YES`：通话历史已到最后一页
    let lastPage: Bool
    /// `-CuePadPhoneVoicePages YES`：通话历史分页
    let pages: Bool
    /// `-CuePadPhoneVoiceRefreshRequired YES`：通话要求刷新
    let refreshRequired: Bool
    let replay: String?
    /// `-CuePadPhoneVoiceSessionUnavailable YES`：通话会话不可用
    let sessionUnavailable: Bool
}
#endif
