#if os(macOS)
import Foundation
import Testing
@testable import CuePi

/// 安装器只在临时 agent 目录里装，且用假 `pi` 脚本报版本；绝不碰真实 ~/.pi。
struct InstallerTests {
    let root: URL
    let paths: PiPaths
    let bin: URL
    var installedFile: URL { paths.extensionsDirectory.appending(path: "cuepad-bridge.ts") }

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

    private func installer() -> PiExtensionInstaller {
        PiExtensionInstaller(paths: paths, locator: PiExecutableLocator(searchDirectories: [bin]))
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

    @Test func foreignFileWithSameNameIsNeverOverwritten() async throws {
        try fakePi(printing: "0.87.1")
        try writeInstalled("export default function () { /* mine */ }\n")
        #expect(await installer().status().file == .foreign)

        await #expect(throws: PiInstallError.foreignFile) { try await installer().install() }
        #expect(try String(contentsOf: installedFile, encoding: .utf8) == "export default function () { /* mine */ }\n")

        try installer().uninstall()
        #expect(FileManager.default.fileExists(atPath: installedFile.path))
    }

    @Test func installRefusesWithoutSupportedPiAndWritesNothing() async throws {
        await #expect(throws: PiInstallError.piNotFound) { try await installer().install() }
        try fakePi(printing: "0.84.3")
        await #expect(throws: PiInstallError.piTooOld(found: PiVersion(0, 84, 3))) { try await installer().install() }
        #expect(!FileManager.default.fileExists(atPath: paths.extensionsDirectory.path))
    }

    @Test func uninstallRemovesOurFileAndIsIdempotent() async throws {
        try fakePi(printing: "0.87.1")
        try await installer().install()
        try installer().uninstall()
        #expect(!FileManager.default.fileExists(atPath: installedFile.path))
        try installer().uninstall()
    }
}
#endif
