#if os(macOS)
import Foundation
import Testing
@testable import CuePi

/// 安装器只在临时目录里装（Pi 目录与链接目录都在里面），且用假 `pi` 脚本报版本；绝不碰真实 ~/.pi 与 ~/.local/bin。
/// 接入、移除、别人的文件、App 移动后修复的端到端用例在 App 的测试里（`PiConnectTests`）。
struct InstallerTests {
    let root: URL
    let paths: PiPaths
    let bin: URL
    var installedFile: URL { paths.extensionsDirectory.appending(path: "cuepad-bridge.ts") }
    var skillFile: URL { paths.skillsDirectory.appending(path: "cuepad/SKILL.md") }
    var link: URL { paths.binDirectory.appending(path: "cuepad") }

    init() throws {
        root = try makeTempDirectory()
        paths = PiPaths(agentDirectory: root.appending(path: "agent"), socketDirectory: root.appending(path: "s"), binDirectory: root.appending(path: "home/.local/bin"))
        bin = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    private func installer() -> PiIntegration {
        PiIntegration(
            paths: paths, locator: PiExecutableLocator(searchDirectories: [bin]),
            helper: root.appending(path: "CuePad.app/Contents/Helpers/cuepad"), shellPath: { nil })
    }

    private func fakePi(printing output: String) throws {
        let script = bin.appending(path: "pi")
        try "#!/bin/sh\nprintf '%s\\n' '\(output)'\n".write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
    }

    private func exists(_ file: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: file.path)) != nil  // 不跟随链接：失效的链接也算在
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

    // MARK: 三样一起写

    /// 三样一起写：最后一步（建链接）失败时，已写的扩展与 skill 还原成原来的样子（原来没有就删掉），不留半接入的状态。
    @Test func aFailureMidwayRestoresWhatWasAlreadyWritten() async throws {
        try fakePi(printing: "0.87.1")
        let old = "// CuePad Pi bridge extension\nconst EXTENSION_VERSION = 1;\n"
        try FileManager.default.createDirectory(at: paths.extensionsDirectory, withIntermediateDirectories: true)
        try old.write(to: installedFile, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: paths.binDirectory, withIntermediateDirectories: true)
        chmod(paths.binDirectory.path, 0o500)  // 链接目录不可写：链接建不出来
        defer { chmod(paths.binDirectory.path, 0o755) }

        await #expect(throws: (any Error).self) { try await installer().install() }
        #expect(try String(contentsOf: installedFile, encoding: .utf8) == old)
        #expect(!exists(skillFile))
        #expect(!exists(link))

        try FileManager.default.removeItem(at: installedFile)  // 原来没有扩展：失败后仍然没有
        await #expect(throws: (any Error).self) { try await installer().install() }
        #expect(!exists(installedFile))
        #expect(!exists(skillFile))
    }

    @Test func installRefusesWithoutSupportedPiAndWritesNothing() async throws {
        await #expect(throws: PiInstallError.piNotFound) { try await installer().install() }
        try fakePi(printing: "0.84.3")
        await #expect(throws: PiInstallError.piTooOld(found: PiVersion(0, 84, 3))) { try await installer().install() }
        #expect(!exists(paths.extensionsDirectory))
        #expect(!exists(paths.skillsDirectory))
        #expect(!exists(paths.binDirectory))
    }
}
#endif
