#if os(macOS)
import CueStore
import Foundation

/// Claude Code 的钩子：CuePad 的条目写在 `<配置目录>/settings.json` 的 `hooks` 键里（Claude Code 把各层配置的钩子合并着跑，
/// 用户级的就是这一份）。每个事件一组 `{"hooks": [{"type": "command", "command": "<cuepad> hook claude", "timeout": …}]}`，
/// 加在该事件已有的组后面；别人的组、别的键原样留着，文件按原文改（`ClaudeJSONText`），卸载后与装之前逐字节一致，
/// 因此空出来的事件、`hooks` 键一并删掉，只剩一个空对象时连文件也删。认 CuePad 的组只看命令（路径可能是旧位置）。
struct ClaudeCodeHooks: AgentHookConfig {
    let home: URL

    /// 上报状态的事件同步跑（保持先后），CuePad 当场放行；权限确认（也覆盖 AskUserQuestion）挡住等 CuePad 答复，
    /// 终端里同时照常弹出，哪边先答算哪边。
    static let events = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest",
        "Stop", "StopFailure", "PreCompact", "PostCompact", "SubagentStart", "SubagentStop", "PostModelSwitch",
    ]

    /// 放行的事件 CuePad 收到就回，CuePad 卡住时也不让 Claude Code 等太久；权限确认要等人答，给足一天
    private static func timeout(_ event: String) -> Int { event == "PermissionRequest" ? 86_400 : 10 }

    var settings: URL { home.appending(path: "settings.json") }

    func files(command: String) -> AgentStatus.Files {
        guard let data = try? Data(contentsOf: settings) else { return .missing }
        let text = ClaudeJSONText(data)
        guard let root = try? text.root(), let hooks = root.member("hooks")?.value, hooks.kind == .object else { return .missing }
        var found = false, current = true
        for member in hooks.items where member.value.kind == .array {
            let mine = member.value.items.filter { isMine(ClaudeJSON.parse(text.text(of: $0.value))) }
            guard !mine.isEmpty else { continue }
            found = true
            let expected = Self.events.contains(member.key ?? "") ? Self.group(command: command, event: member.key ?? "") : nil
            if mine.count != 1 || ClaudeJSON.parse(text.text(of: mine[0].value)) != expected { current = false }
        }
        guard found else { return .missing }
        let complete = Self.events.allSatisfy { event in
            hooks.member(event)?.value.items.contains { ClaudeJSON.parse(text.text(of: $0.value)) == Self.group(command: command, event: event) } == true
        }
        return current && complete ? .current : .outdated
    }

    func install(command: String) async throws {
        var text = try removingMine(from: (try? Data(contentsOf: settings)) ?? Data("{}\n".utf8))
        let root = try text.root()
        if root.member("hooks") == nil { text.append(key: "hooks", in: root) { _, _ in "{}" } }
        for event in Self.events {
            let hooks = try hooksObject(of: text)
            if let existing = hooks.member(event)?.value {
                guard existing.kind == .array else { throw ClaudeHooksError.unexpectedShape(settings.path) }
                text.append(key: nil, in: existing) { indent, unit in Self.groupText(command: command, event: event, indent: indent, unit: unit) }
            } else {
                text.append(key: event, in: hooks) { indent, unit in
                    "[\n\(indent)\(unit)\(Self.groupText(command: command, event: event, indent: indent + unit, unit: unit))\n\(indent)]"
                }
            }
        }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try text.data.write(to: settings, options: .atomic)
    }

    func uninstall() async throws {
        guard let data = try? Data(contentsOf: settings) else { return }
        let text = try removingMine(from: data)
        guard text.data != data else { return }
        if text.isEmptyObject {
            try FileManager.default.removeItem(at: settings)
        } else {
            try text.data.write(to: settings, options: .atomic)
        }
    }

    // MARK: 条目

    private func isMine(_ group: ClaudeJSON?) -> Bool {
        guard let hooks = group?["hooks"]?.array, !hooks.isEmpty else { return false }
        return hooks.allSatisfy { $0["command"]?.string.map(Self.isCuePadCommand) == true }
    }

    /// `<cuepad 的路径> hook claude`：路径可能带引号、可能是 App 搬家前的旧位置
    private static func isCuePadCommand(_ command: String) -> Bool {
        let suffix = " hook \(AgentKind.claudeCode.rawValue)"
        guard command.hasSuffix(suffix) else { return false }
        let executable = command.dropLast(suffix.count).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        return URL(filePath: executable).lastPathComponent == "cuepad"
    }

    private static func group(command: String, event: String) -> ClaudeJSON {
        ["hooks": [["type": "command", "command": .string(command), "timeout": .number(Double(timeout(event)))]]]
    }

    private static func groupText(command: String, event: String, indent: String, unit: String) -> String {
        let inner = indent + unit + unit
        return """
            {
            \(indent + unit)"hooks": [
            \(indent + unit + unit){
            \(inner + unit)"type": "command",
            \(inner + unit)"command": \(ClaudeJSONText.quoted(command)),
            \(inner + unit)"timeout": \(timeout(event))
            \(inner)}
            \(indent + unit)]
            \(indent)}
            """
    }

    private func hooksObject(of text: ClaudeJSONText) throws -> ClaudeJSONText.Node {
        guard let hooks = try text.root().member("hooks")?.value, hooks.kind == .object else { throw ClaudeHooksError.unexpectedShape(settings.path) }
        return hooks
    }

    /// 删掉 CuePad 的组；因此空了的事件、`hooks` 对象一并删（用户自己留的空结构不碰）。文件不是 JSON 对象就不动它、抛错。
    private func removingMine(from data: Data) throws -> ClaudeJSONText {
        var text = ClaudeJSONText(data)
        guard let root = try? text.root(), root.kind == .object else { throw ClaudeHooksError.unreadable(settings.path) }
        while true {
            guard let hooks = try text.root().member("hooks")?.value, hooks.kind == .object else { return text }
            let found = hooks.items.lazy.compactMap { member -> (event: String, group: Int, in: ClaudeJSONText.Node)? in
                guard member.value.kind == .array,
                      let group = member.value.items.firstIndex(where: { isMine(ClaudeJSON.parse(text.text(of: $0.value))) }) else { return nil }
                return (member.key ?? "", group, member.value)
            }.first
            guard let found else { return text }
            text.remove(found.group, in: found.in)
            let emptied = try hooksObject(of: text)
            if let (index, array) = emptied.member(found.event), array.items.isEmpty { text.remove(index, in: emptied) }
            let root = try text.root()
            if let (index, hooks) = root.member("hooks"), hooks.items.isEmpty { text.remove(index, in: root) }
        }
    }
}

enum ClaudeHooksError: Error, Equatable, LocalizedError {
    /// settings.json 不是 JSON 对象（写坏了）：不覆盖它
    case unreadable(String)
    /// `hooks` 或其中某个事件不是对象、数组
    case unexpectedShape(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let path): "\(path) 不是有效的 JSON，没有改动"
        case .unexpectedShape(let path): "\(path) 里的 hooks 格式不对，没有改动"
        }
    }
}
#endif
