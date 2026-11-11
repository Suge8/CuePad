#if os(macOS)
import CueStore
import CueText
import Foundation

extension CodexRuntime {
    /// 服务端请求：权限确认（命令、改文件、MCP 工具）与挡着这一轮的提问；别的（MCP 的表单等）不接，回错误。
    func request(_ method: String, _ params: JSONValue, id: JSONValue, on rpc: CodexRPC) -> Bool {
        guard let threadID = params["threadId"]?.string, let session = tracked["\(threadID).\(rpc.pid)"] else { return false }
        let accept: JSONValue = ["decision": "accept"], decline: JSONValue = ["decision": "decline"]
        switch method {
        case "item/tool/requestUserInput":
            return userInput(params, id: id, on: rpc, in: session)
        case "item/commandExecution/requestApproval":
            let actions = (params["commandActions"]?.array ?? []).compactMap { $0["command"]?.string }
            let command = actions.isEmpty ? params["command"]?.string : actions.joined(separator: "\n")
            ask(session, String(localized: "运行命令"), [command, params["reason"]?.string], .approval(rpc, id: id, allow: accept, deny: decline))
        case "item/fileChange/requestApproval":
            ask(session, String(localized: "使用 \("apply_patch")"), [params["reason"]?.string], .approval(rpc, id: id, allow: accept, deny: decline))
        case "mcpServer/elicitation/request" where params["_meta"]?["codex_approval_kind"]?.string == "mcp_tool_call":
            let tool = ToolDetail.name("mcp__\(params["serverName"]?.string ?? "")__\(params["_meta"]?["tool_name"]?.string ?? "")")
            let allow: JSONValue = ["action": "accept", "content": .null, "_meta": .null], deny: JSONValue = ["action": "decline", "content": .null, "_meta": .null]
            ask(session, String(localized: "使用 \(tool)"), [], .approval(rpc, id: id, allow: allow, deny: deny))
        default:
            return false
        }
        return true
    }

    private func ask(_ session: Tracked, _ action: String, _ details: [String?], _ reply: Tracked.Reply) {
        session.reply = reply
        session.facts.questions = [Question(promptID: UUID().uuidString, kind: .confirm, text: PermissionWording.question(.codex, action, details))]
        publish(session)
    }

    private func userInput(_ params: JSONValue, id: JSONValue, on rpc: CodexRPC, in session: Tracked) -> Bool {
        let questions = params["questions"]?.array ?? []
        let answerable = questions.count == 1 && questions.first?["isSecret"]?.bool != true
        let question = Self.userInput(params, promptID: answerable ? UUID().uuidString : nil)
        session.reply = nil
        if answerable, let first = questions.first?["id"]?.string { session.reply = .question(rpc, id: id, question: first) }
        session.facts.questions = [question]
        publish(session)
        return answerable
    }

    private static func userInput(_ arguments: JSONValue, promptID: String?) -> Question {
        let first = arguments["questions"]?.array?.first ?? .object([:])
        let text = [first["header"]?.string, first["question"]?.string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        let options = (first["options"]?.array ?? []).compactMap { $0["label"]?.string }
        return Question(
            promptID: promptID, kind: options.isEmpty ? .text : .select, text: String(text.prefix(500)), options: options,
            allowsOther: first["isOther"]?.bool == true)
    }

    /// `request_user_input_async` 一次可以问几个，标题就是完整的问题；Codex 的界面总给自由作答，所以只有一个时也能自己填。
    static func asyncQuestion(_ questions: JSONValue?) -> Question? {
        let questions = (questions?.array ?? []).compactMap { question -> (title: String, options: [String])? in
            guard let title = question["title"]?.string, !title.isEmpty else { return nil }
            return (title, (question["options"]?.array ?? []).compactMap(\.string))
        }
        guard let first = questions.first else { return nil }
        guard questions.count > 1 else {
            return Question(
                promptID: UUID().uuidString, kind: first.options.isEmpty ? .text : .select, text: String(first.title.prefix(500)),
                options: first.options, allowsOther: !first.options.isEmpty)
        }
        let text = questions.map { $0.options.isEmpty ? $0.title : "\($0.title)（\($0.options.joined(separator: " / "))）" }.joined(separator: "\n")
        return Question(promptID: UUID().uuidString, kind: .text, text: String(text.prefix(500)))
    }

    public func answer(_ answer: AnswerValue, to promptID: String, in id: Session.ID) async throws {
        guard let session = tracked[id], let question = session.facts.question else { throw BridgeError.rejected("no_prompt") }
        guard question.promptID == promptID else { throw BridgeError.rejected("stale_prompt") }
        guard let reply = session.reply else {
            let text: String
            switch answer {
            case .option(let option) where question.options.contains(option): text = option
            case .text(let written) where question.acceptsText: text = written
            default: throw BridgeError.rejected("bad_answer")
            }
            try await deliver(CodexRPC.input(text: text, images: []), clientID: CodexHistory.clientID(for: nil), to: session)
            session.facts.standingQuestion = nil
            return publish(session)
        }
        switch (reply, answer) {
        case (.approval(let rpc, let requestID, let allow, let deny), .confirmed(let allowed)):
            rpc.respond(to: requestID, result: allowed ? allow : deny)
        case (.question(let rpc, let requestID, let questionID), .option(let text)) where question.options.contains(text),
             (.question(let rpc, let requestID, let questionID), .text(let text)) where question.acceptsText:
            rpc.respond(to: requestID, result: ["answers": [questionID: ["answers": [.string(text)]]]])
        default:
            throw BridgeError.rejected("bad_answer")
        }
        session.reply = nil
        session.facts.questions = []
        publish(session)
    }
}
#endif
