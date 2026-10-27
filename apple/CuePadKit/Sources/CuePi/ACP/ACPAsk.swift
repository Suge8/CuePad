#if os(macOS)
import CueStore
import Foundation

/// Agent 发来、要你回答的一问：标准的权限确认（`permission`），或各家自己的提问请求（`ACPDialect.ask`）翻成的。
/// 驱动只认这一种：托管会话把它放进 CuePad 的提问（`promptID` 由驱动给），作答经 `answer` 翻回去；没答就作废（这一轮停下、结束，
/// 或又来一问）时回 `withdrawn`。一个请求里有几问的（分批提问）逐问来：`answer` 回下一问，最后一问答完才回给 Agent。
struct ACPAsk {
    var question: PiQuestion
    /// 你的答案：回给 Agent 的结果、接着问的下一问；答案不合这一问为 nil（`bad_answer`）
    var answer: (PiAnswerValue) -> ACPReply?
    var withdrawn: JSONValue
}

enum ACPReply {
    case result(JSONValue)
    case next(ACPAsk)
}

extension ACPAsk {
    /// 权限确认（`session/request_permission`）：允许回 allow_once（没有就 allow_always），拒绝回 reject_once（没有就 reject_always），
    /// 作废回 `cancelled`（协议要求）。
    static func permission(_ params: JSONValue, agent: AgentKind, dialect: any ACPDialect) -> ACPAsk {
        let options = params["options"]?.array ?? []
        let call = params["toolCall"] ?? [:]
        let name = ToolDetail.name(dialect.tool(call).name)
        let text = PermissionWording.question(agent, String(localized: "使用 \(name)"), [ToolDetail.target(call["rawInput"]), call["title"]?.string])
        return ACPAsk(question: PiQuestion(promptID: nil, kind: .confirm, text: text), answer: { answer in
            guard case .confirmed(let allowed) = answer else { return nil }
            return selected(options, allowed ? ["allow_once", "allow_always"] : ["reject_once", "reject_always"]).map(ACPReply.result)
        }, withdrawn: ["outcome": ["outcome": "cancelled"]])
    }

    /// 大脑没人可问：权限一律允许（它只有读文件与 CuePad 的工具）
    static func allowed(_ params: JSONValue) -> JSONValue {
        selected(params["options"]?.array ?? [], ["allow_once", "allow_always"]) ?? ["outcome": ["outcome": "cancelled"]]
    }

    private static func selected(_ options: [JSONValue], _ kinds: [String]) -> JSONValue? {
        kinds.lazy.compactMap { kind in options.first { $0["kind"]?.string == kind }?["optionId"] }.first
            .map { ["outcome": ["outcome": "selected", "optionId": $0]] }
    }
}
#endif
