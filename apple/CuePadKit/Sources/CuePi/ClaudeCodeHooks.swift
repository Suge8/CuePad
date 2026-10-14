#if os(macOS)
import CueStore
import Foundation

/// Claude Code 的钩子：CuePad 的条目写在 `<配置目录>/settings.json` 的 `hooks` 键里（Claude Code 把各层配置的钩子合并着跑，
/// 用户级的就是这一份）。每个事件一组 `{"hooks": [{"type": "command", "command": "<cuepad> hook claude", "timeout": …}]}`，
/// 加在该事件已有的组后面；别人的组、别的键原样留着，文件按原文改（`ClaudeJSONText`）。卸载删回装之前的样子、逐字节一致：
/// CuePad 新加的事件、`hooks` 键、整个文件整项删，用户原有的（哪怕空着）只删其中 CuePad 的组。认 CuePad 的组只看命令（路径可能是旧位置）。
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
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // 没有文件、或文件是 CuePad 建的且之后没人动过（升级换了路径）：整个写成 CuePad 建的样子，卸载时整个删
        let data = try? Data(contentsOf: settings)
        guard let data, !commands(in: data).contains(where: { data == Data(Self.fileText(command: $0).utf8) }) else {
            return try Data(Self.fileText(command: command).utf8).write(to: settings, options: .atomic)
        }
        var text = try removingMine(from: data)
        let root = try text.root()
        guard let hooks = root.member("hooks")?.value else {
            text.append(key: "hooks", in: root) { Self.hooksText(command: command, indent: $0, unit: $1) }
            return try text.data.write(to: settings, options: .atomic)
        }
        guard hooks.kind == .object else { throw ClaudeHooksError.unexpectedShape(settings.path) }
        for event in Self.events {
            let hooks = try hooksObject(of: text)
            if let existing = hooks.member(event)?.value {
                guard existing.kind == .array else { throw ClaudeHooksError.unexpectedShape(settings.path) }
                text.append(key: nil, in: existing) { Self.groupText(command: command, event: event, indent: $0, unit: $1) }
            } else {
                text.append(key: event, in: hooks) { Self.eventText(command: command, event: event, indent: $0, unit: $1) }
            }
        }
        try text.data.write(to: settings, options: .atomic)
    }

    func uninstall() async throws {
        guard let data = try? Data(contentsOf: settings) else { return }
        // 文件是 CuePad 建的、之后没人动过：整个删掉（装之前没有它）
        if let command = commands(in: data).first, data == Data(Self.fileText(command: command).utf8) {
            return try FileManager.default.removeItem(at: settings)
        }
        let text = try removingMine(from: data)
        guard text.data != data else { return }
        try text.data.write(to: settings, options: .atomic)
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

    /// CuePad 新加的一个事件的值：只有它那一组的数组
    private static func eventText(command: String, event: String, indent: String, unit: String) -> String {
        "[\n\(indent + unit)\(groupText(command: command, event: event, indent: indent + unit, unit: unit))\n\(indent)]"
    }

    /// CuePad 新加的 `hooks` 对象：全部事件
    private static func hooksText(command: String, indent: String, unit: String) -> String {
        let inner = indent + unit
        let members = events.map { "\(inner)\(ClaudeJSONText.quoted($0)): \(eventText(command: command, event: $0, indent: inner, unit: unit))" }
        return "{\n\(members.joined(separator: ",\n"))\n\(indent)}"
    }

    /// 原来没有 settings.json 时 CuePad 建的整个文件
    private static func fileText(command: String) -> String {
        "{\n  \"hooks\": \(hooksText(command: command, indent: "  ", unit: "  "))\n}\n"
    }

    /// 文件里 CuePad 条目用的命令（可能是 App 搬家前的旧路径）
    private func commands(in data: Data) -> [String] {
        let groups = ClaudeJSON.parse(data)?["hooks"]?.object?.values.flatMap { $0.array ?? [] } ?? []
        return groups.filter(isMine).compactMap { $0["hooks"]?.array?.first?["command"]?.string }
    }

    private func hooksObject(of text: ClaudeJSONText) throws -> ClaudeJSONText.Node {
        guard let hooks = try text.root().member("hooks")?.value, hooks.kind == .object else { throw ClaudeHooksError.unexpectedShape(settings.path) }
        return hooks
    }

    /// 删掉 CuePad 加的东西，每一处都删回 `append` 之前的样子：CuePad 新加的 `hooks` 对象、新加的事件原样还在（文字与 `append` 写出的一致）就整项删掉，
    /// 否则只删其中 CuePad 的组；用户自己的结构（哪怕空着）不删。文件不是 JSON 对象就不动它、抛错。
    private func removingMine(from data: Data) throws -> ClaudeJSONText {
        var text = ClaudeJSONText(data)
        guard let root = try? text.root(), root.kind == .object else { throw ClaudeHooksError.unreadable(settings.path) }
        while true {
            let root = try text.root()
            guard let (hooksIndex, hooks) = root.member("hooks"), hooks.kind == .object else { return text }
            let command = commands(in: text.data).first
            if let command, text.itemText(hooksIndex, in: root)
                == text.itemText(key: "hooks", in: root, render: { Self.hooksText(command: command, indent: $0, unit: $1) }) {
                text.remove(hooksIndex, in: root)
                continue
            }
            if let command, let event = hooks.items.indices.first(where: { index in
                let key = hooks.items[index].key ?? ""
                return Self.events.contains(key) && text.itemText(index, in: hooks)
                    == text.itemText(key: key, in: hooks, render: { Self.eventText(command: command, event: key, indent: $0, unit: $1) })
            }) {
                text.remove(event, in: hooks)
                continue
            }
            let group = hooks.items.lazy.compactMap { member -> (index: Int, in: ClaudeJSONText.Node)? in
                guard member.value.kind == .array,
                      let index = member.value.items.firstIndex(where: { isMine(ClaudeJSON.parse(text.text(of: $0.value))) }) else { return nil }
                return (index, member.value)
            }.first
            guard let group else { return text }
            text.remove(group.index, in: group.in)
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
