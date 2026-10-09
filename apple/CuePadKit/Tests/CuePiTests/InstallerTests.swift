#if os(macOS)
import Foundation
import Testing
@testable import CuePi

/// 安装器只在临时 agent 目录里装，且用假 `pi` 脚本报版本；绝不碰真实 ~/.pi。
struct InstallerTests {
    let root: URL
    let paths: PiPaths
    let bin: URL
    /// App 里的命令行工具（skill 里写它的绝对路径）
    var cuepad: URL { root.appending(path: "CuePad.app/Contents/Helpers/cuepad") }
    var installedFile: URL { paths.extensionsDirectory.appending(path: "cuepad-bridge.ts") }
    var skillFile: URL { paths.skillsDirectory.appending(path: "cuepad/SKILL.md") }

    /// 随包分发的扩展源文件（事实源）
    static var bundledSource: String {
        get throws {
            let file = URL(filePath: #filePath).deletingLastPathComponent()
                .appending(path: "../../Sources/CuePi/Extension/cuepad-bridge.ts").standardized
            return try String(contentsOf: file, encoding: .utf8)
        }
    }

    init() throws {
        root = try makeTempDirectory()
        paths = PiPaths(agentDirectory: root.appending(path: "agent"), socketDirectory: root.appending(path: "s"))
        bin = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    private func installer(cuepad: URL? = nil) -> PiIntegration {
        PiIntegration(paths: paths, locator: PiExecutableLocator(searchDirectories: [bin]), cuepad: cuepad ?? self.cuepad)
    }

    private func fakePi(printing output: String) throws {
        let script = bin.appending(path: "pi")
        try "#!/bin/sh\nprintf '%s\\n' '\(output)'\n".write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
    }

    private func writeInstalled(_ text: String) throws {
        try FileManager.default.createDirectory(at: paths.extensionsDirectory, withIntermediateDirectories: true)
        try text.write(to: installedFile, atomically: true, encoding: .utf8)
    }

    // MARK: Pi 版本检测

    @Test(arguments: [
        ("0.87.1", PiVersion(0, 87, 1), true),
        ("0.84.4", PiVersion(0, 84, 4), true),
        ("0.84.3", PiVersion(0, 84, 3), false),
        ("v1.0.0", PiVersion(1, 0, 0), true),
        ("0.9.9", PiVersion(0, 9, 9), false),
    ])
    func detectsPiVersionAndSupport(output: String, version: PiVersion, supported: Bool) async throws {
        try fakePi(printing: output)
        let status = await installer().status()
        guard case .found(_, let found) = status.pi else { Issue.record("pi not found: \(status)"); return }
        #expect(found == version)
        #expect(status.pi.isSupported == supported)
    }

    @Test func reportsPiNotFoundWhenMissingOrNotPi() async throws {
        #expect(await installer().status().pi == .notFound)
        try fakePi(printing: "command not found: hello")
        #expect(await installer().status().pi == .notFound)
        try fakePi(printing: "0.87.1") // 对照：同一目录里换成真版本号就能找到
        #expect(await installer().status().pi.isSupported)
    }

    @Test func statusHasNoSideEffects() async throws {
        try fakePi(printing: "0.87.1")
        #expect(await installer().status().pi.isSupported)
        #expect(!FileManager.default.fileExists(atPath: paths.agentDirectory.path))
    }

    // MARK: 安装 / 升级 / 卸载

    @Test func installWritesBundledExtensionAndBecomesCurrent() async throws {
        try fakePi(printing: "0.87.1")
        #expect(await installer().status().file == .missing)

        try await installer().install()

        #expect(try String(contentsOf: installedFile, encoding: .utf8) == Self.bundledSource)
        #expect(await installer().status().file == .current)
        let source = try Self.bundledSource
        let declared = try #require(source.firstMatch(of: /const EXTENSION_VERSION = (\d+);/).flatMap { Int($0.1) })
        #expect(PiExtensionBundle.version == declared && declared > 0)
    }

    @Test func olderInstalledCopyIsDetectedAndUpgraded() async throws {
        try fakePi(printing: "0.87.1")
        try writeInstalled("// CuePad Pi bridge extension\nconst EXTENSION_VERSION = 0;\n")
        #expect(await installer().status().file == .outdated(installed: 0))

        try await installer().install()

        #expect(await installer().status().file == .current)
        #expect(try String(contentsOf: installedFile, encoding: .utf8) == Self.bundledSource)
    }

    // MARK: skill（和扩展一起装、一起升级）

    /// 用户同意的那一次装两样：扩展，和一个很短的 skill（写着 App 里 cuepad 的绝对路径，Pi 从 skills 目录发现它）。
    @Test func installWritesTheSkillWithTheCLIPathAlongsideTheExtension() async throws {
        try fakePi(printing: "0.87.1")

        try await installer().install()

        let skill = try String(contentsOf: skillFile, encoding: .utf8)
        #expect(skill == PiSkillBundle.text(cuepad: cuepad))
        #expect(skill.hasPrefix("---\nname: cuepad\n") && skill.contains("\(cuepad.path) show <文件>") && skill.contains("\(cuepad.path) --help"))
        #expect(await installer().status().file == .current)
    }

    /// 默认的 Pi 目录下 skill 装进 ~/.agents/skills（Pi、以后的 Codex 与 Claude Code 都读同一份约定）；换了 Pi 目录（隔离、测试）就跟着走。
    @Test func skillsDirectoryIsTheSharedAgentsOneOnlyForTheDefaultPiDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(PiPaths(environment: [:]).skillsDirectory.path == home.appending(path: ".agents/skills").path)
        #expect(paths.skillsDirectory.path == paths.agentDirectory.appending(path: "skills").path)
    }

    /// App 被移动后 cuepad 的路径变了：skill 算旧版，启动时与扩展一起重写。
    @Test func aMovedAppMakesTheSkillOutdatedAndInstallRewritesIt() async throws {
        try fakePi(printing: "0.87.1")
        try await installer().install()
        let moved = root.appending(path: "Other/CuePad.app/Contents/Helpers/cuepad")

        let status = await installer(cuepad: moved).status()
        #expect(status.file == .outdated(installed: PiExtensionBundle.version))

        try await installer(cuepad: moved).install()
        #expect(try String(contentsOf: skillFile, encoding: .utf8).contains(moved.path))
        #expect(await installer(cuepad: moved).status().file == .current)
    }

    /// 以前只装了扩展的用户：扩展是最新的、skill 缺，也算旧版，升级时补上。
    @Test func anExtensionWithoutTheSkillIsOutdatedAndUpgradeAddsTheSkill() async throws {
        try fakePi(printing: "0.87.1")
        try writeInstalled(try Self.bundledSource)
        #expect(await installer().status().file == .outdated(installed: PiExtensionBundle.version))

        try await installer().install()

        #expect(FileManager.default.fileExists(atPath: skillFile.path))
        #expect(await installer().status().file == .current)
    }

    /// 没装扩展就是"未安装"（要先征得同意），哪怕 skill 还留着。
    @Test func withoutTheExtensionItIsMissingEvenIfASkillRemains() async throws {
        try fakePi(printing: "0.87.1")
        try FileManager.default.createDirectory(at: skillFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PiSkillBundle.text(cuepad: cuepad).write(to: skillFile, atomically: true, encoding: .utf8)
        #expect(await installer().status().file == .missing)
    }

    /// 用户自己的同名 skill 不覆盖，扩展也不装：两样一起拒绝。
    @Test func aForeignSkillWithTheSameNameStopsTheWholeInstallAndIsNeverOverwritten() async throws {
        try fakePi(printing: "0.87.1")
        try FileManager.default.createDirectory(at: skillFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nname: cuepad\n---\n我自己的\n".write(to: skillFile, atomically: true, encoding: .utf8)
        #expect(await installer().status().file == .foreign)

        await #expect(throws: PiInstallError.foreignFile) { try await installer().install() }
        #expect(try String(contentsOf: skillFile, encoding: .utf8) == "---\nname: cuepad\n---\n我自己的\n")
        #expect(!FileManager.default.fileExists(atPath: installedFile.path))
    }

    @Test func foreignFileWithSameNameIsNeverOverwritten() async throws {
        try fakePi(printing: "0.87.1")
        try writeInstalled("export default function () { /* mine */ }\n")
        #expect(await installer().status().file == .foreign)

        await #expect(throws: PiInstallError.foreignFile) { try await installer().install() }
        #expect(try String(contentsOf: installedFile, encoding: .utf8) == "export default function () { /* mine */ }\n")
    }

    @Test func installRefusesWithoutSupportedPiAndWritesNothing() async throws {
        await #expect(throws: PiInstallError.piNotFound) { try await installer().install() }
        try fakePi(printing: "0.84.3")
        await #expect(throws: PiInstallError.piTooOld(found: PiVersion(0, 84, 3))) { try await installer().install() }
        #expect(!FileManager.default.fileExists(atPath: paths.extensionsDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: paths.skillsDirectory.path))
    }
}
#endif
