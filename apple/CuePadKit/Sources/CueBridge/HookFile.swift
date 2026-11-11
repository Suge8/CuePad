#if os(macOS)
import CueStore
import Foundation

/// 迁移代码（#202）：旧版 CuePad 接入 Claude Code、Codex 时往它们的配置里写过钩子（命令 `<cuepad> hook <agent>`），现在接入只写技能。
/// 启动时删掉 CuePad 的条目，旧版都升级后连同这两个文件、`JSONSourceTree` 与 `cuepad hook` 一起删。
extension AgentIntegration {
    /// 不看这家此刻接没接入；隔离运行不能动的目录不碰。Codex 的信任要起 `codex` 才删得掉，`codex` 为 nil 时留到找得到它的那次启动。
    /// 一家没删成不影响另一家，抛第一个错；没删成的下次启动再删。
    @concurrent public func removeOldHooks(codex: URL?) async throws {
        var failure: OldHooksError?
        if isWritable(.claudeCode) {
            let hooks = HookFile(agent: .claudeCode, file: home(of: .claudeCode).appending(path: "settings.json"), skillDirectory: skillDirectory)
            do { try hooks.remove() } catch { failure = OldHooksError(file: hooks.file, reason: error) }
        }
        if isWritable(.codex) {
            let hooks = CodexHooks(home: home(of: .codex), skillDirectory: skillDirectory, codex: codex, locate: locate, environment: paths.environment)
            do { try await hooks.remove() } catch { failure = failure ?? OldHooksError(file: hooks.hooks.file, reason: error) }
        }
        // 记录放在 CuePad 自己的技能目录里：没接入任何一家时删完只剩空目录
        if touchesShared, (try? FileManager.default.contentsOfDirectory(atPath: skillDirectory.path))?.isEmpty == true { try? FileManager.default.removeItem(at: skillDirectory) }
        if let failure { throw failure }
    }
}

struct OldHooksError: LocalizedError {
    let file: URL
    let reason: any Error

    var errorDescription: String? {
        String(localized: "CuePad 以前写进 \(UserHome.shown(file.path)) 的钩子没能删掉，下次启动再试：\(reason.localizedDescription)")
    }
}

/// Claude Code 的 `settings.json`、Codex 的 `hooks.json` 两家同一种结构：
/// `{"hooks": {"<事件>": [{"matcher"?, "hooks": [{"type": "command", "command", …}]}]}}`。认 CuePad 的组只看命令（路径可能是 App 的旧位置）。
///
/// - 按原文就地删（`JSONSourceTree`），用户的格式、键序与未知键一字不动。
/// - CuePad 建的结构（文件、`hooks`、事件数组）空了一并删掉：哪些是 CuePad 建的，旧版装时记在 `Footprint`（CuePad 技能目录里），
///   删完连它一起删。记录丢了时什么结构都当作用户的，只删组。
/// - 文件不是 JSON 时：有记录就抛错、不改它；没记录就当没有 CuePad 的条目。
struct HookFile {
    let agent: AgentKind
    let file: URL
    let footprintFile: URL

    init(agent: AgentKind, file: URL, skillDirectory: URL) {
        self.agent = agent
        self.file = file
        footprintFile = skillDirectory.appending(path: "\(agent.rawValue)-hooks.json")
    }

    struct Footprint: Codable, Equatable {
        var file: Bool
        var hooksObject = false
        var events: [String] = []
        /// Codex 的信任写在另一个文件（`config.toml`）里，它装之前的样子（`CodexHooks`）
        var config: CodexHooks.ConfigFootprint?

        static let unknown = Footprint(file: true)
    }

    func footprint() -> Footprint? {
        (try? Data(contentsOf: footprintFile)).flatMap { try? JSONDecoder().decode(Footprint.self, from: $0) }
    }

    /// 下标是 Codex 信任的键要用的。
    func ourGroups(in tree: JSONSourceTree) -> [(event: String, index: Int)] {
        (tree.root.member("hooks")?.members ?? []).flatMap { member in
            (member.value.elements ?? []).enumerated().filter { isOurs($0.element, in: tree.text) }.map { (member.key, $0.offset) }
        }
    }

    func remove() throws {
        let recorded = FileManager.default.fileExists(atPath: footprintFile.path)
        let footprint = footprint() ?? .unknown
        if let original = try? Data(contentsOf: file) {
            guard (try? JSONSourceTree(original)) != nil else {
                if recorded { throw HookFileError.malformed }
                return
            }
            let text = try removingOurs(from: original, dropping: footprint)
            if !footprint.file, try JSONSourceTree(text).root.members.isEmpty {
                try FileManager.default.removeItem(at: file)
            } else if text != original {
                try text.write(to: file, options: .atomic)
            }
        }
        if recorded { try FileManager.default.removeItem(at: footprintFile) }
    }

    private func isOurCommand(_ command: String) -> Bool {
        let suffix = " hook \(agent.rawValue)"
        guard command.hasSuffix(suffix) else { return false }
        let executable = command.dropLast(suffix.count).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        return URL(filePath: executable).lastPathComponent == "cuepad"
    }

    private func isOurs(_ node: JSONSourceTree.Node, in text: Data) -> Bool {
        let group = (try? JSONSerialization.jsonObject(with: text[node.range])) as? [String: Any]
        return ((group?["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String).map(isOurCommand) ?? false }
    }

    /// 一次删一处、重新扫描。
    private func removingOurs(from text: Data, dropping footprint: Footprint) throws -> Data {
        var text = text
        while true {
            let tree = try JSONSourceTree(text)
            guard let hooks = tree.root.member("hooks") else { return text }
            if let array = hooks.members.first(where: { $0.value.elements?.contains { isOurs($0, in: text) } == true })?.value {
                text = array.removing(element: array.elements!.firstIndex { isOurs($0, in: text) }!, in: text)
                continue
            }
            if let event = hooks.members.first(where: { footprint.events.contains($0.key) && $0.value.elements?.isEmpty == true })?.key {
                text = hooks.removing(member: event, in: text)
            } else if footprint.hooksObject, hooks.members.isEmpty {
                return tree.root.removing(member: "hooks", in: text)
            } else {
                return text
            }
        }
    }
}

enum HookFileError: Error, Equatable, LocalizedError {
    case malformed

    var errorDescription: String? { String(localized: "文件不是有效的 JSON，CuePad 没有改它") }
}
#endif
