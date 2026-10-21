#if os(macOS)
import CueStore
import Foundation

extension OpenCodeRuntime {
    func apply(_ event: OpenCodeEvent, _ connection: Connection) async {
        let data = event.data
        switch event.type {
        case "model.updated", "command.updated":
            guard let directory = event.location?.directory, catalogs[directory] != nil else { return }
            _ = try? await catalog(directory, connection.client, reload: true)
            for (id, tracked) in sessions where tracked.directory == directory { publish(id) }
            return
        // 子代理要你确认的也挂在顶层会话上（它在等，整个会话就在等）；作答时按标识里记的会话答
        case "permission.asked":
            guard let sessionID = data.sessionID, let id = data.id else { return }
            let question = Self.question(OpenCodePermission(id: id, sessionID: sessionID, action: data.action ?? "", resources: data.resources ?? []))
            await change(topLevel(sessionID), connection, active: true) { $0.facts.questions.append(question) }
            return
        case "permission.replied":
            guard let sessionID = data.sessionID, let id = data.requestID else { return }
            await change(topLevel(sessionID), connection) { $0.facts.questions.removeAll { $0.promptID == Self.prompt(.permission, sessionID, id) } }
            return
        case "form.created":
            guard let form = data.form else { return }
            await change(topLevel(form.sessionID), connection, active: true) { $0.facts.questions.append(Self.question(form)) }
            return
        case "form.replied", "form.cancelled":
            guard let sessionID = data.sessionID, let id = data.id else { return }
            await change(topLevel(sessionID), connection) { $0.facts.questions.removeAll { $0.promptID == Self.prompt(.form, sessionID, id) } }
            return
        default: break
        }
        guard event.type.hasPrefix("session."), let sessionID = data.sessionID else { return }
        if let parent = data.parentID ?? parents[sessionID] {
            if event.type != "session.text.delta" { child(sessionID, of: parent, event) }
            return
        }
        if let (id, draft) = drafts.apply(event) { bridge.setDraft(bridgeID(id, connection), draft) }
        switch event.type {
        case "session.created":
            guard let location = data.location else { return }
            let now = Date().timeIntervalSince1970 * 1000
            let info = OpenCodeSessionInfo(
                id: sessionID, title: data.title, agent: data.agent, model: data.model, location: location, time: .init(created: now, updated: now))
            if sessions[sessionID] == nil { sessions[sessionID] = Tracked(info: info) }
            listed?.insert(sessionID)
            await change(sessionID, connection, active: true) { _ in }
        case "session.deleted":
            guard let tracked = sessions.removeValue(forKey: sessionID) else { return }
            if tracked.online { bridge.detach(bridgeID(sessionID, connection), reason: .closed(reason: "deleted")) }
            listed?.remove(sessionID)
            await retainIndex()
        case "session.renamed":
            await change(sessionID, connection) { $0.info.title = data.title }
        case "session.model.selected":
            await change(sessionID, connection) { $0.info.model = data.model }
        case "session.inbox.enqueued":
            await change(sessionID, connection, active: true) {
                if $0.firstMessage == nil { $0.firstMessage = data.item?.payload?.text.map { String($0.prefix(PiSessionName.firstMessageLimit)) } }
            }
        case "session.inbox.delivered":
            enqueueIngest(sessionID, urgent: true)
        case "session.execution.started":
            await change(sessionID, connection, active: true) { $0.facts.startTurn(at: .now) }
        case "session.step.started":
            // 没给会话选过模型时它用配置里的默认模型：每一步都带着实际用的那个
            await change(sessionID, connection) {
                $0.facts.work(.thinking)
                if let model = data.model { $0.info.model = model }
            }
        case "session.reasoning.started":
            await change(sessionID, connection) { $0.facts.work(.thinking) }
        case "session.tool.input.started":
            guard let id = data.id, let name = data.name else { return }
            await change(sessionID, connection) { $0.toolNames[id] = name }
        case "session.tool.called":
            guard let id = data.id else { return }
            await change(sessionID, connection) { $0.facts.work(.tool, detail: ToolDetail.line($0.toolNames[id] ?? "tool", data.input?.arguments)) }
        case "session.tool.success", "session.tool.failed":
            await change(sessionID, connection) {
                if let id = data.id { $0.toolNames[id] = nil }
                if $0.toolNames.isEmpty { $0.facts.work(.thinking) }
            }
        case "session.step.ended":
            await change(sessionID, connection) { if let tokens = data.tokens { $0.tokens = tokens.context } }
            enqueueIngest(sessionID, urgent: true)
        case "session.compaction.started":
            await change(sessionID, connection, active: true) { $0.facts.compacting = true }
        case "session.compaction.ended", "session.compaction.failed":
            await change(sessionID, connection) {
                $0.facts.compacting = false
                if event.type == "session.compaction.ended" { $0.tokens = nil }
            }
            enqueueIngest(sessionID, urgent: true)
        case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted":
            await change(sessionID, connection) {
                $0.toolNames = [:]
                let failure = event.type == "session.execution.failed" ? (data.error?.message ?? data.error?.type ?? Self.unknownFailure) : nil
                let questions = $0.facts.questions
                $0.facts.endTurn(failure: failure)
                $0.facts.questions = questions  // 权限与表单随它们自己的事件收起
            }
            enqueueIngest(sessionID, urgent: true)
        default:
            break
        }
    }

    /// 改一个顶层会话并发布。`active`：这是一次活动，会话不在线就上线（在 CuePad 里结束过的也重新上线）。
    /// 不认识的会话（连上之后才建、事件先于列表）先取它的信息。
    private func change(_ sessionID: String, _ connection: Connection, active: Bool = false, _ body: (inout Tracked) -> Void) async {
        if sessions[sessionID] == nil {
            guard active, let info = try? await connection.client.get(OpenCodeData<OpenCodeSessionInfo>.self, "/api/session/\(sessionID)").data,
                  info.parentID == nil, self.connection === connection else { return }
            sessions[sessionID] = sessions[sessionID] ?? Tracked(info: info)
        }
        guard var tracked = sessions[sessionID] else { return }
        body(&tracked)
        if active, !tracked.online {
            tracked.online = true
            ended[sessionID] = nil
        }
        sessions[sessionID] = tracked
        if tracked.online, catalogs[tracked.directory] == nil { _ = try? await catalog(tracked.directory, connection.client) }
        publish(sessionID)
    }

    /// 子会话的事件落到父会话的子代理名册上。
    func child(_ sessionID: String, of parent: String, _ event: OpenCodeEvent) {
        parents[sessionID] = parent
        let data = event.data
        let now = Date()
        subagent(sessionID, of: parent) { agent in
            switch event.type {
            case "session.created":
                agent.name = data.title ?? ""
                agent.role = data.agent ?? ""
                agent.startedAt = now
            case "session.execution.started":
                agent.phase = .known(.running)
                agent.settledAt = nil
            case "session.tool.input.started":
                if let id = data.id, let name = data.name { childTools[id] = name }
            case "session.tool.called":
                agent.action = ToolDetail.line(data.id.flatMap { childTools.removeValue(forKey: $0) } ?? "tool", data.input?.arguments)
            case "session.execution.succeeded":
                agent.phase = .known(.done)
                agent.action = ""
                agent.settledAt = now
            case "session.execution.failed":
                agent.phase = .known(.failed)
                agent.action = data.error?.message ?? ""
                agent.settledAt = now
            case "session.execution.interrupted":
                agent.phase = .known(.interrupted)
                agent.action = ""
                agent.settledAt = now
            default: break
            }
        }
        publish(parent)
    }

    func subagent(_ id: String, of parent: String, _ body: (inout PiSubagentState) -> Void) {
        guard var tracked = sessions[parent] else { return }
        let now = Date()
        if !tracked.facts.subagents.contains(where: { $0.id == id }) { tracked.facts.startSubagent(id, name: "", role: "", at: now) }
        tracked.facts.updateSubagent(id, at: now, body)
        // 执行中的子会话就是在飞的
        tracked.facts.inFlight = Set(tracked.facts.subagents.filter { $0.state.phase == .known(.running) }.map(\.id))
        sessions[parent] = tracked
    }

    func topLevel(_ sessionID: String) -> String { parents[sessionID] ?? sessionID }

    /// 弹窗的标识：种类、提问的会话（可能是子代理）、它的请求 id。
    enum PromptKind: String { case permission, form }

    static func prompt(_ kind: PromptKind, _ sessionID: String, _ id: String) -> String { "\(kind.rawValue):\(sessionID)/\(id)" }

    static func parse(_ promptID: String) -> (kind: PromptKind, sessionID: String, id: String)? {
        let parts = promptID.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let kind = PromptKind(rawValue: String(parts[0])) else { return nil }
        let rest = parts[1].split(separator: "/", maxSplits: 1)
        guard rest.count == 2 else { return nil }
        return (kind, String(rest[0]), String(rest[1]))
    }

    static func question(_ permission: OpenCodePermission) -> PiQuestion {
        let text = PermissionWording.question(.opencode, "使用 \(permission.action)", permission.resources)
        return PiQuestion(
            promptID: prompt(.permission, permission.sessionID, permission.id), kind: .select, text: text,
            options: [allowOnce, allowAlways, reject])
    }

    /// 只有一个字段的表单能从 CuePad 答（`question` 工具问一个问题时就是这样）：有选项的是选择，文字是填空，是否是确认；其余只能在 OpenCode 里答。
    static func question(_ form: OpenCodeForm) -> PiQuestion {
        guard form.fields.count == 1, let field = form.fields.first else {
            return PiQuestion(promptID: nil, kind: .unknown("form"), text: String((form.title ?? "").prefix(500)))
        }
        let text = String([field.title, field.description].compactMap { $0 }.joined(separator: "\n").prefix(500))
        switch field.type {
        case "string" where field.options?.isEmpty == false:
            return PiQuestion(
                promptID: prompt(.form, form.sessionID, form.id), kind: .select, text: text, options: field.options!.map(\.label),
                allowsOther: field.custom == true)
        case "string": return PiQuestion(promptID: prompt(.form, form.sessionID, form.id), kind: .text, text: text)
        case "boolean": return PiQuestion(promptID: prompt(.form, form.sessionID, form.id), kind: .confirm, text: text)
        default: return PiQuestion(promptID: nil, kind: .unknown(field.type), text: text)
        }
    }
}
#endif
