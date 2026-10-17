#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePi

/// 接入 Agent 只在临时目录里装：各家的配置目录经它们自己认的环境变量指到临时目录，`pi` 是报版本的假脚本；绝不碰真实的 ~/.pi、~/.claude 等。
struct AgentIntegrationTests {
    let root: URL
    let paths: PiPaths
    let bin: URL
    /// App 里的命令行工具（技能里写它的绝对路径）
    var cuepad: URL { root.appending(path: "CuePad.app/Contents/Helpers/cuepad") }
    var environment: [String: String] {
        ["CLAUDE_CONFIG_DIR": root.appending(path: "claude").path, "CODEX_HOME": root.appending(path: "codex").path,
         "XDG_CONFIG_HOME": root.appending(path: "xdg").path]
    }
    var extensionFile: URL { paths.extensionsDirectory.appending(path: "cuepad-bridge.ts") }

    /// 各家文档里个人技能的位置（Pi 的目录由 `PiPaths` 定）
    func skillFile(_ kind: AgentKind) -> URL {
        let home = switch kind {
        case .pi: paths.agentDirectory
        case .claudeCode: root.appending(path: "claude")
        case .codex: root.appending(path: "codex")
        case .opencode: root.appending(path: "xdg/opencode")
        }
        return home.appending(path: "skills/cuepad/SKILL.md")
    }

    init() throws {
        root = try makeTempDirectory()
        paths = PiPaths(agentDirectory: root.appending(path: "pi"), socketDirectory: root.appending(path: "s"))
        bin = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    private func integration(cuepad: URL? = nil) -> AgentIntegration {
        AgentIntegration(paths: AgentPaths(pi: paths, environment: environment), locate: { ExecutableLocator(searchDirectories: [bin]) }, cuepad: cuepad ?? self.cuepad)
    }

    private func fakeAgent(_ command: String, printing output: String = "") throws {
        let script = bin.appending(path: command)
        try "#!/bin/sh\nprintf '%s\\n' '\(output)'\n".write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
    }

    private func installAll() throws {
        try fakeAgent("pi", printing: "0.90.0")
        for command in ["claude", "codex"] { try fakeAgent(command) }
        try fakeAgent("opencode", printing: "2.0.25")
    }

    private func contents(_ directory: URL) -> [String] {
        FileManager.default.subpaths(atPath: directory.path)?.sorted() ?? []
    }

    // MARK: 检测

    @Test(arguments: [
        ("0.87.1", AgentStatus.Presence.found(AgentVersion(0, 87, 1))),
        ("v1.0.0", .found(AgentVersion(1, 0, 0))),
        ("0.84.3", .tooOld(AgentVersion(0, 84, 3))),
        ("command not found: hello", .notFound),
    ])
    func detectsPiByItsReportedVersion(output: String, presence: AgentStatus.Presence) async throws {
        try fakeAgent("pi", printing: output)
        #expect(await integration().status(of: .pi).presence == presence)
    }

    /// 检测在征得同意之前就跑：不写任何东西。没装、也没用过的 Agent 是没找到；有命令或有配置目录（用过它，含桌面版）就算在。
    @Test func detectionFindsAgentsByCommandOrConfigDirectoryAndWritesNothing() async throws {
        try FileManager.default.createDirectory(at: root.appending(path: "codex"), withIntermediateDirectories: true)
        try fakeAgent("claude")
        let before = contents(root)

        #expect(await integration().status(of: .claudeCode) == AgentStatus(presence: .found(nil), files: .missing, executable: bin.appending(path: "claude")))
        #expect(await integration().status(of: .codex) == AgentStatus(presence: .found(nil), files: .missing))
        #expect(await integration().status(of: .opencode) == AgentStatus(presence: .notFound, files: .missing))
        #expect(await integration().status(of: .pi) == AgentStatus(presence: .notFound, files: .missing))
        #expect(contents(root) == before)
    }

    // MARK: 接入与删除

    /// 每家的技能写进它自己文档里的个人技能目录，正文写着 App 里 cuepad 的绝对路径与手机预览（show），Codex 的提醒沙箱。
    /// 关掉时 CuePad 写的文件与因此空出来的目录都删掉，配置目录里别的东西不动。
    /// Codex 的钩子要真 codex 来信任，它的接入与删除见 `CodexHooksTests`。
    @Test(arguments: AgentKind.allCases.filter { $0 != .codex })
    func installWritesTheSkillWhereTheAgentReadsItAndUninstallLeavesNoTrace(kind: AgentKind) async throws {
        try installAll()
        let home = skillFile(kind).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try #"{"theme": "用户自己的"}"#.write(to: home.appending(path: "settings.json"), atomically: true, encoding: .utf8)
        let before = contents(root)

        try await integration().install(kind)

        let skill = try String(contentsOf: skillFile(kind), encoding: .utf8)
        #expect(skill.hasPrefix("---\nname: cuepad\ndescription: "))
        #expect(skill.contains("\(cuepad.path) --help"))
        #expect(skill.contains("\(cuepad.path) show <文件…>"))
        #expect(skill.contains("沙箱") == (kind == .codex))
        #expect(FileManager.default.fileExists(atPath: extensionFile.path) == (kind == .pi))
        #expect(await integration().status(of: kind).files == .current)

        try await integration().uninstall(kind)

        #expect(contents(root) == before)
        #expect(await integration().status(of: kind).files == .missing)
    }

    /// Agent 已经卸掉了，CuePad 留下的技能照样能删干净。
    @Test func uninstallWorksAfterTheAgentIsGone() async throws {
        try fakeAgent("claude")
        try await integration().install(.claudeCode)
        try FileManager.default.removeItem(at: bin.appending(path: "claude"))

        #expect(await integration().status(of: .claudeCode) == AgentStatus(presence: .found(nil), files: .current))  // 配置目录还在：算用过
        try await integration().uninstall(.claudeCode)
        #expect(!FileManager.default.fileExists(atPath: skillFile(.claudeCode).deletingLastPathComponent().path))
    }

    @Test func installRefusesWithoutTheAgentAndWritesNothing() async throws {
        await #expect(throws: AgentInstallError.notFound(.opencode)) { try await integration().install(.opencode) }
        await #expect(throws: AgentInstallError.notFound(.pi)) { try await integration().install(.pi) }
        try fakeAgent("pi", printing: "0.84.3")
        await #expect(throws: AgentInstallError.tooOld(.pi, found: AgentVersion(0, 84, 3))) { try await integration().install(.pi) }
        #expect(contents(root) == ["bin", "bin/pi"])
    }

    /// OpenCode 只认 v2：v1 报的版本太旧，接入被拒、什么都不写（界面据此说"需要 OpenCode 2"）。
    @Test func openCodeVersionOneIsTooOldAndInstallWritesNothing() async throws {
        try fakeAgent("opencode", printing: "1.19.0")
        #expect(await integration().status(of: .opencode) == AgentStatus(presence: .tooOld(AgentVersion(1, 19, 0)), files: .missing))
        await #expect(throws: AgentInstallError.tooOld(.opencode, found: AgentVersion(1, 19, 0))) { try await integration().install(.opencode) }
        #expect(contents(root) == ["bin", "bin/opencode"])

        try fakeAgent("opencode", printing: "2.0.25")
        try await integration().install(.opencode)
        #expect(
            await integration().status(of: .opencode)
                == AgentStatus(presence: .found(AgentVersion(2, 0, 25)), files: .current, executable: bin.appending(path: "opencode")))
    }

    /// 问版本不在 Agent 自己的数据目录里留东西：OpenCode 每次运行（`--version` 也是）都往 `$XDG_DATA_HOME/opencode/log` 写日志，
    /// 检测时它的数据目录是一个用完即删的临时目录。替身照 OpenCode 的样子写日志，并记下给它的数据目录（没给时只记不写，不碰真实目录）。
    @Test func askingTheVersionLeavesNothingInTheAgentsDataDirectory() async throws {
        let record = root.appending(path: "data-home.txt")
        let script = bin.appending(path: "opencode")
        try """
        #!/bin/sh
        printf '%s' "${XDG_DATA_HOME-unset}" > '\(record.path)'
        if [ -n "$XDG_DATA_HOME" ]; then mkdir -p "$XDG_DATA_HOME/opencode/log" && echo started >> "$XDG_DATA_HOME/opencode/log/opencode.log"; fi
        echo 'opencode v2.0.29'
        """.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)

        #expect(await integration().status(of: .opencode).presence == .found(AgentVersion(2, 0, 29)))
        let dataHome = try String(contentsOf: record, encoding: .utf8)
        #expect(dataHome != "unset" && !dataHome.isEmpty, "给了它数据目录，不落到用户的 ~/.local/share")
        #expect(!FileManager.default.fileExists(atPath: dataHome), "临时数据目录用完删掉")
    }

    /// 用户自己的同名技能或扩展不覆盖、不删除；Pi 的两样一起拒绝。
    @Test func foreignFilesWithTheSameNameAreNeverTouched() async throws {
        try installAll()
        let mine = "---\nname: cuepad\n---\n我自己的\n"
        for kind in [AgentKind.claudeCode, .pi] {
            try FileManager.default.createDirectory(at: skillFile(kind).deletingLastPathComponent(), withIntermediateDirectories: true)
            try mine.write(to: skillFile(kind), atomically: true, encoding: .utf8)
            #expect(await integration().status(of: kind).files == .foreign((skillFile(kind).path as NSString).abbreviatingWithTildeInPath))
            await #expect(throws: AgentInstallError.self) { try await integration().install(kind) }
            await #expect(throws: AgentInstallError.self) { try await integration().uninstall(kind) }
            #expect(try String(contentsOf: skillFile(kind), encoding: .utf8) == mine)
        }
        #expect(!FileManager.default.fileExists(atPath: extensionFile.path))
    }

    // MARK: 升级

    /// App 更新或被移动后（cuepad 的路径变了），装过的就是旧版：重装即升级到这个版本。
    @Test func aMovedAppMakesInstalledFilesOutdatedAndInstallRewritesThem() async throws {
        try installAll()
        try await integration().install(.pi)
        let moved = root.appending(path: "Other/CuePad.app/Contents/Helpers/cuepad")

        for kind in [AgentKind.pi] {
            #expect(await integration(cuepad: moved).status(of: kind).files == .outdated)
            try await integration(cuepad: moved).install(kind)
            #expect(try String(contentsOf: skillFile(kind), encoding: .utf8).contains(moved.path))
            #expect(await integration(cuepad: moved).status(of: kind).files == .current)
        }
    }

    @Test func anOlderPiExtensionIsOutdatedAndInstallUpgradesIt() async throws {
        try installAll()
        try FileManager.default.createDirectory(at: paths.extensionsDirectory, withIntermediateDirectories: true)
        try "// CuePad Pi bridge extension\nconst EXTENSION_VERSION = 0;\n".write(to: extensionFile, atomically: true, encoding: .utf8)
        #expect(await integration().status(of: .pi).files == .outdated)

        try await integration().install(.pi)

        #expect(try String(contentsOf: extensionFile, encoding: .utf8) == PiExtensionBundle.source)
    }
}
#endif
