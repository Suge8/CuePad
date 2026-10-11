#if os(macOS)
import Foundation
import Testing
@testable import CuePad

/// `cuepad` 命令行随 App 分发：在 ~/.local/bin 建指向 App 包内二进制的符号链接，让 agent 在 bash 里直接调用。
struct CommandLineToolTests {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "cuepad-cli-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    var helper: URL { root.appending(path: "CuePad.app/Contents/Helpers/cuepad") }
    var linkDirectory: URL { root.appending(path: "home/.local/bin", directoryHint: .isDirectory) }
    var link: URL { linkDirectory.appending(path: "cuepad") }

    init() throws {
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho ok\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    }

    private func makeInstaller(helper: URL? = nil, shellPath: String? = nil) -> CommandLineToolInstaller {
        CommandLineToolInstaller(helper: helper ?? self.helper, linkDirectory: linkDirectory, shellPath: { shellPath })
    }

    private func destination() throws -> String { try FileManager.default.destinationOfSymbolicLink(atPath: link.path) }

    @Test func 安装时创建缺失的目录并建指向App内二进制的链接_卸载即删除() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = makeInstaller()
        await installer.refresh()
        #expect(installer.state == .notInstalled)

        try await installer.install()

        #expect(installer.state == .installed)
        #expect(try destination() == helper.path)
        try await installer.install() // 再装一次是空操作
        #expect(try destination() == helper.path)

        try await installer.uninstall()
        #expect(installer.state == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: link.path))
    }

    @Test func 位置被别的东西占用时不覆盖_明确报错() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
        try "我自己的脚本".write(to: link, atomically: true, encoding: .utf8)
        let installer = makeInstaller()
        await installer.refresh()
        guard case .blocked = installer.state else { Issue.record("状态应为 blocked：\(installer.state)"); return }

        await #expect(throws: CommandLineToolError.occupied(link.path)) { try await installer.install() }
        #expect(try String(contentsOf: link, encoding: .utf8) == "我自己的脚本")
        await #expect(throws: CommandLineToolError.occupied(link.path)) { try await installer.uninstall() }
        #expect(FileManager.default.fileExists(atPath: link.path))

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/usr/bin/true")
        await installer.refresh()
        await #expect(throws: CommandLineToolError.occupied(link.path)) { try await installer.install() }
        #expect(try destination() == "/usr/bin/true")
    }

    @Test func App移动位置后链接失效_检测到并可修复() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/Volumes/Old/CuePad.app/Contents/Helpers/cuepad")
        let installer = makeInstaller()

        await installer.refresh()
        #expect(installer.state == .stale)

        try await installer.install()
        #expect(installer.state == .installed)
        #expect(try destination() == helper.path)
    }

    @Test(arguments: [
        ("/usr/bin:/bin", false),
        ("/usr/bin:__LINK__:/bin", true),
    ])
    func 提示链接目录是否在shell的PATH里(path: String, included: Bool) async {
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = makeInstaller(shellPath: path.replacingOccurrences(of: "__LINK__", with: linkDirectory.path))
        await installer.refresh()
        #expect(installer.pathIncludesLinkDirectory == included)
    }

    /// 测试宿主就是这次构建出的 CuePad.app：里面必须真的带着 cuepad，经链接调用能运行。
    @Test func 真实构建里经链接调用cuepad_help可运行() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let real = Bundle.main.bundleURL.appending(path: "Contents/Helpers/cuepad")
        let installer = makeInstaller(helper: real)
        try await installer.install()
        #expect(installer.state == .installed)

        let process = Process()
        process.executableURL = link
        process.arguments = ["--help"]
        process.environment = ["CUEPAD_LIBRARY_DIR": root.appending(path: "library").path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("cuepad"))
    }
}

struct CommandLineToolRowTests {
    @Test(arguments: [
        (true as Bool?, false, "已安装：~/.local/bin/cuepad"),
        (false as Bool?, true, "不在你的 shell 的 PATH 里"),
        (nil as Bool?, true, "没能读取你的 shell PATH，请确认 ~/.local/bin 在 PATH 中"),
    ])
    func 已安装时按PATH检查结果提示_读不出来也要明说(included: Bool?, warning: Bool, expected: String) {
        let detail = CommandLineToolRow.detail(state: .installed, pathIncludesLinkDirectory: included)
        #expect(detail.isWarning == warning)
        #expect(detail.text.contains(expected))
    }
}
#endif
