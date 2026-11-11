#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CueBridge

let pinnedGrok = PinnedAgent.grok

/// Grok 起来用的环境：HOME 与配置目录是给的临时目录，模型地址指到本用例的假模型（Responses），密钥是假的。
/// 产品起 Grok 时把它盖在测试进程的环境上，所以每一项都要给：空串会顶掉假密钥（Grok 报 "no auth method id provided"）。
func grokEnvironment(model: FakeModel, home: URL, grokHome: URL) -> [String: String] {
    ["HOME": home.path, "GROK_HOME": grokHome.path, "GROK_XAI_API_BASE_URL": "\(model.baseURL)/v1", "XAI_API_KEY": "fake-xai-key",
     "GROK_AUTH_PATH": grokHome.appending(path: "no-login.json").path, "GROK_DISABLE_AUTOUPDATER": "1", "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost"]
}

/// 用例的话写成真模型也照做的英文；假模型照这几句演。Grok 把你的话包在 `<user_query>` 里，工具的名字是它自己的（`run_terminal_command`、
/// `ask_user_question`），MCP 工具只经 `use_tool` 交给模型。
extension FakeModel {
    func playGrok() {
        on({ $0.prompt.contains("<user_query>") }) { request in
            let images = request.images.isEmpty ? "" : " IMAGES[\(request.images.joined(separator: ","))]"
            return .say("ECHO \(Self.query(request.prompt))\(images)")
        }
        on({ $0.system.hasPrefix("You are tasked with generating the session title") }) { _ in .say("Probe session") }
        on({ $0.system.hasPrefix("Write an ultra-short dashboard") }) { _ in .say("Probe summary") }
        on({ Self.query($0.prompt).contains("What color is this image") }) { .say($0.images.isEmpty ? "I see no image" : "red") }
        on({ Self.query($0.prompt).contains("Remember the word") }) { _ in .say("OK") }
        on({ Self.query($0.prompt).contains("What word did I ask you to remember") }) { request in
            .say(request.said.lazy.compactMap { $0.firstMatch(of: /Remember the word (\w+)/)?.1 }.first.map(String.init) ?? "UNKNOWN")
        }
        on({ Self.query($0.prompt).contains("numbers from 1 to 400") }) { _ in .stream(["1\n", "2\n", "3\n"]) }
        on({ Self.query($0.prompt).contains("ask_user_question") }) { request in
            let questions: [[String: any Sendable]] = [
                ["question": "Which drink?", "header": "Drink", "multiSelect": false,
                 "options": [["label": "Tea", "description": "hot"], ["label": "Coffee", "description": "strong"]]],
                ["question": "Which size?", "header": "Size", "multiSelect": false,
                 "options": [["label": "Small", "description": "small cup"], ["label": "Large", "description": "large cup"]]],
            ]
            return request.step == 0 ? .call("ask_user_question", ["questions": questions]) : .say(request.results.last ?? "")
        }
        on({ Self.query($0.prompt).contains("run exactly:") }) { request in
            let command = Self.query(request.prompt).firstMatch(of: /run exactly: (.+?)  Then/)?.1 ?? "true"
            return request.step == 0 ? .call("run_terminal_command", ["command": String(command), "description": "run it"]) : .say("DONE")
        }
    }

    /// 大脑用例（`playBrain`）在 Grok 上的写法：MCP 的 echo 经 `use_tool`，写文件只有终端命令。
    func playGrokBrain(chain: FakeGate) {
        playGrok()
        playBrain(chain: chain)
        on({ $0.prompt.contains("Create a file named") }) { request in
            request.step == 0 ? .call("run_terminal_command", ["command": "echo x > hack.txt", "description": "write the file"]) : .say("I could not create it.")
        }
        on({ $0.prompt.contains("Call the echo tool") }) { request in
            let next = FakeReply.call("use_tool", ["tool_name": "cuepad__echo", "tool_input": ["text": request.results.last ?? "x"]])
            return switch request.step {
            case 0: .call("use_tool", ["tool_name": "cuepad__echo", "tool_input": ["text": "x"]])
            case 1: .held(chain, then: next)
            case 8...: .say(request.results.last ?? "")
            default: next
            }
        }
    }

    private static func query(_ prompt: String) -> String {
        prompt.components(separatedBy: "<user_query>").last?.components(separatedBy: "</user_query>").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? prompt
    }
}

/// 临时的 Grok 配置目录、家目录与工作目录：钉住的真 Grok（`pinnedGrok`）起在这里，连本用例的假模型，不读写真实的 ~/.grok 与资料库。
@MainActor
final class GrokRig {
    let root: URL
    let model: FakeModel
    let bridge: Bridge
    let runtime: GrokRuntime
    var home: URL { root.appending(path: "grok", directoryHint: .isDirectory) }
    var work: URL { root.appending(path: "work", directoryHint: .isDirectory) }

    init() async throws {
        try pinnedGrok.require()
        root = try makeTempDirectory().resolvingSymlinksInPath()
        let model = try await FakeModel()
        model.playGrok()
        self.model = model
        for directory in [root.appending(path: "grok"), root.appending(path: "work"), root.appending(path: "user")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let sockets = root.appending(path: "s", directoryHint: .isDirectory)
        let environment = grokEnvironment(model: model, home: root.appending(path: "user"), grokHome: root.appending(path: "grok"))
            .merging(["CUEPAD_PI_SOCKET_DIR": sockets.path, "CUEPAD_LIBRARY_DIR": root.appending(path: "library").path]) { $1 }
        let paths = AgentPaths(pi: PiPaths(agentDirectory: root.appending(path: "pi"), socketDirectory: sockets), environment: environment)
        bridge = Bridge(socketDirectory: sockets)
        runtime = GrokRuntime(bridge: bridge, paths: paths, grok: { pinnedGrok.executable }, locate: { pinnedGrok.locator }, timing: noDeadline)
        try bridge.start()
        try runtime.start()
    }

    func open(_ launchToken: String) async throws -> Session.ID {
        try await runtime.open(in: work, launchToken: launchToken, name: nil, model: nil, thinking: nil)
    }

    func stop() async {
        await runtime.stop()()
        bridge.stop()
        model.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func transcript(_ session: Session) throws -> HistoryUpdate {
        try History.index(file: try #require(session.sessionFile), agent: .grok, from: nil, files: scratchFiles)
    }

    func replies(_ session: Session) -> [String] {
        ((try? transcript(session))?.messages ?? []).filter { $0.role == .known(.pi) }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// 最近一条回答里有这个词
    func replied(_ word: String, in id: Session.ID) -> Bool {
        bridge.session(id: id).flatMap { replies($0).last?.contains(word) } == true
    }

    /// 交给模型主对话的请求里，最近一条你的话含这句的（Grok 另有起标题、写摘要的请求，它们的系统提示不同）
    func asked(_ text: String) -> [FakeRequest] {
        model.requests.filter { $0.system.hasPrefix("You are Grok") && $0.prompt.contains(text) }
    }

    /// 会话的进程是钉住的那份 Grok（不是别处的另一个），并且在跑
    func runsPinnedGrok(_ id: Session.ID) -> Bool {
        guard let pid = bridge.session(id: id)?.pid else { return false }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        return URL(filePath: String(cString: path)).resolvingSymlinksInPath().path == pinnedGrok.executable.resolvingSymlinksInPath().path
    }
}

@MainActor
func withGrokRig(_ body: (GrokRig) async throws -> Void) async throws {
    let rig = try await GrokRig()
    do { try await body(rig) } catch { await rig.stop(); throw error }
    await rig.stop()
}
#endif
