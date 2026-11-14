#if os(macOS)
import Foundation

extension VoiceCall {
    /// 实时模型唯一的一条开发者消息（`initial_items`）：会话的 `instructions` 字段实测不生效（要它只说法语照样说中文、自称 ChatGPT），所以不发。
    /// 委派与播报靠服务端默认行为；往开发者消息里加规则（#105）或任务、灵感标题作背景（#109）都会让英文建任务不再委派并谎称已办好，背景越长越重，不要加。
    /// 不给头衔：写成 the user's assistant 时它自称“助手”；把三种问法与 answer as name 换成 when asked about yourself 时，“能做什么”会自称 ChatGPT（#128 对照）。
    static func identity(name: String) -> String {
        """
        You are \(name) in CuePad: you capture the user's ideas, manage their tasks and direct the agents on their Mac. \
        When asked who you are, your name or what you can do, answer as \(name) with this role, never as an assistant. \
        Never say you are ChatGPT, OpenAI or any underlying model, and never mention a backend.
        """
    }
}

protocol VoiceControl: AnyObject {
    func send(_ outgoing: VoiceWire.Outgoing) async throws
    func close()
}
#endif
