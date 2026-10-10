#if os(macOS)
import Foundation
import Testing

/// 桥扩展由 Pi 在运行时加载（类型在加载时被擦掉），没有任何构建步骤检查它调用的 Pi 接口。
/// 这里用本机 Pi 的类型声明与它检出里的 TypeScript 做严格类型检查：Pi 改了扩展接口，这一条先红。
private struct PiTypes {
    let packageRoot: URL
    let tsc: URL
    let nodeTypes: URL

    /// `~/.local/bin/pi` 指向的检出：向上找带类型声明（dist/index.d.ts）的包目录，再向上找带 typescript 与 @types 的 node_modules。
    init?() {
        guard realPiAvailable else { return nil }
        var directory = realPiURL.resolvingSymlinksInPath().deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appending(path: "dist/index.d.ts").path) {
            guard directory.path != "/" else { return nil }
            directory.deleteLastPathComponent()
        }
        packageRoot = directory
        var found: (tsc: URL, types: URL)?
        while directory.path != "/", found == nil {
            directory.deleteLastPathComponent()
            let modules = directory.appending(path: "node_modules")
            let tsc = modules.appending(path: ".bin/tsc"), types = modules.appending(path: "@types")
            if FileManager.default.isExecutableFile(atPath: tsc.path), FileManager.default.fileExists(atPath: types.path) { found = (tsc, types) }
        }
        guard let found else { return nil }
        (tsc, nodeTypes) = found
    }
}

@Suite(.enabled(if: PiTypes() != nil, "需要 ~/.local/bin/pi 指向带 node_modules/.bin/tsc 的 Pi 检出"))
struct ExtensionTypesTests {
    @Test func bridgeTypechecksAgainstInstalledPi() throws {
        let pi = try #require(PiTypes())
        let bridge = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/CuePi/Extension/cuepad-bridge.ts").standardized
        let config: [String: Any] = [
            "compilerOptions": [
                "target": "ES2023", "module": "NodeNext", "strict": true, "noEmit": true, "skipLibCheck": true,
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
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        #expect(process.terminationStatus == 0, "tsc:\n\(text)")
    }
}
#endif
