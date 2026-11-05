#if os(macOS)
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

extension RealHostTests {
    /// v38 及更早的扩展（自己盯着扩展目录、不认 `upgrade`，见 `PiExtensionBundle.lastDiskWatchingVersion`）：取自仓库历史里的最后一版，
    /// 装进 Pi 扩展目录的样子与当年的 CuePad 装的一样。
    enum DiskWatchingExtension: String, CaseIterable, Sendable {
        /// v37：单文件
        case singleFile
        /// v38：目录
        case directory

        func install(into extensions: URL) throws {
            switch self {
            case .singleFile:
                try git("show", "f1667afaa^:apple/CuePadKit/Sources/CuePi/Extension/cuepad-bridge.ts").write(to: extensions.appending(path: PiExtensionBundle.legacyFileName))
            case .directory:
                let commit = "2e755b416^", source = "apple/CuePadKit/Sources/CuePi/Extension/cuepad-bridge/"
                let target = extensions.appending(path: PiExtensionBundle.directoryName, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                for path in String(decoding: try git("ls-tree", "--full-tree", "--name-only", commit, source), as: UTF8.self).split(separator: "\n") {
                    try git("show", "\(commit):\(path)").write(to: target.appending(path: String(path.split(separator: "/").last!)))
                }
            }
        }

        private func git(_ arguments: String...) throws -> Data {
            let process = Process(), output = Pipe()
            process.executableURL = URL(filePath: "/usr/bin/git")
            process.arguments = ["-C", fixturesDirectory.path] + arguments
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0, "git \(arguments.joined(separator: " "))")
            return data
        }
    }

    /// 开着这类旧扩展的两个会话，一个歇着、一个正忙：CuePad 装上新扩展后，歇着的马上换上，正忙的这一轮照常做完、歇下后换上，
    /// 两个都是原来的进程；都换过来后旧单文件删掉。Pi 1.4.0 的官方二进制（Bun 1.3）会吞掉同一毫秒里排在后面的目录事件，
    /// 要覆盖它就用 `CUEPAD_PI` 指过去（见 `RealAgents`）。
    @Test(RealAgents.live(.pi, "旧扩展取自仓库历史，两个进程交替换扩展"), arguments: DiskWatchingExtension.allCases)
    func sessionsOnADiskWatchingExtensionComeBackOnTheNewOne(_ old: DiskWatchingExtension) async throws {
        let pi = try await PiProcess(modelInAgentDirectory: true)
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        try await eventually("桥发现会话") { !bridge.sessions.isEmpty }
        pi.kill(SIGTERM)
        try await eventually("会话结束") { bridge.sessions.isEmpty }
        let installed = PiExtensionFiles(extensionsDirectory: pi.paths.extensionsDirectory) { await !bridge.allRun(extensionVersion: PiExtensionBundle.version) }
        try FileManager.default.removeItem(at: installed.directory)
        try old.install(into: pi.paths.extensionsDirectory)
        let idle = try await PiProcess(alongside: pi)
        defer { idle.stop() }
        let busy = try await PiProcess(alongside: pi)
        defer { busy.stop() }
        try await eventually("两个旧扩展的会话上了桥") { Set(bridge.sessions.filter(\.upgrading).map(\.pid)) == [idle.pid, busy.pid] }
        try busy.prompt("[[slow]] 正忙")
        try await busy.waitUntilHeld()
        let busyFile = try #require(bridge.sessions.first { $0.pid == busy.pid }?.sessionFile)

        let host = PiRuntime(bridge: bridge, paths: pi.paths, pi: { AgentTape.executable("pi") })
        host.start()
        // App 在 Pi 会话上线、下线时复查旧单文件（`AgentIntegrations.retireLegacyPiExtension`）
        let changes = bridge.changes()
        let retiring = Task {
            for await change in changes {
                switch change {
                case .appeared, .ended: try installed.retireLegacyFile(inUse: !bridge.allRun(extensionVersion: PiExtensionBundle.version))
                default: break
                }
            }
        }
        defer { retiring.cancel() }
        try await installed.install(command: "")
        host.integrationInstalled()

        func onTheNewExtension(_ process: PiProcess) -> Bool { bridge.sessions.contains { $0.pid == process.pid && !$0.upgrading } }
        try await eventually("歇着的换上新扩展") { onTheNewExtension(idle) }
        #expect(!onTheNewExtension(busy), "正忙的不打断这一轮")
        try busy.release()
        try await eventually("正忙的做完这一轮") { fileTexts("assistant", in: busyFile).last == "ECHO [[slow]] 正忙 IMAGES[]" }
        try await eventually("正忙的歇下后换上新扩展") { onTheNewExtension(busy) }
        try await eventually("旧单文件删掉") { !FileManager.default.fileExists(atPath: pi.paths.extensionsDirectory.appending(path: PiExtensionBundle.legacyFileName).path) }
    }
}
#endif

