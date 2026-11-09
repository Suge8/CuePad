#if os(macOS)
import CueTestSupport
import Foundation
import Testing

/// 桥扩展由 Pi 在运行时加载（类型在加载时被擦掉），没有任何构建步骤检查它调用的 Pi 接口。
/// 这里用钉住的 Pi 的类型声明与随它装的 TypeScript（`Tests/agents.json` 的 `with`）做严格类型检查：Pi 改了扩展接口，这一条先红。
private struct PiTypes {
    private var modules: URL { pinnedPi.bin.deletingLastPathComponent().appending(path: "node_modules") }
    var packageRoot: URL { modules.appending(path: "@earendil-works/pi-coding-agent") }
    var tsc: URL { modules.appending(path: ".bin/tsc") }
    var nodeTypes: URL { modules.appending(path: "@types") }
}

@Suite(RealAgents.taped(.pi))
struct ExtensionTypesTests {
    @Test func bridgeTypechecksAgainstInstalledPi() async throws {
        try pinnedPi.require()
        let pi = PiTypes()
        let bridge = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/CuePi/Extension/cuepad-bridge/index.ts").standardized
        let config: [String: Any] = [
            "compilerOptions": [
                "target": "ES2023", "module": "NodeNext", "strict": true, "noEmit": true, "skipLibCheck": true, "allowImportingTsExtensions": true,
                "types": ["node"], "typeRoots": [pi.nodeTypes.path],
                "paths": ["@earendil-works/pi-coding-agent": [pi.packageRoot.appending(path: "dist/index.d.ts").path]],
            ],
            "files": [bridge.path],
        ]
        let directory = try makeTempDirectory()
        let project = directory.appending(path: "tsconfig.json")
        try JSONSerialization.data(withJSONObject: config).write(to: project)

        let process = Process()
        process.executableURL = pi.tsc
        process.arguments = ["-p", project.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let exit = try ProcessExit(launching: process)
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        #expect(await exit.value == 0, "tsc:\n\(text)")
    }
}
#endif
