import Foundation
import Testing

/// 一行里用"·"隔开几段的字只经 `Dotted`（屏幕写"·"、读屏读逗号）：源码里别处直接写 " · " 或单独的 Text("·") 会让读屏念出它。
/// 扫 App 下所有目标的源码（主 App、小组件、分享与通知扩展）。例外：`Dotted` 自己与 `Dot`（Atoms.swift）、同步数据格式（PiProgress.swift）、演示库里模仿存储内容的假数据（Debug/）。
@Suite struct DotSeparatorTests {
    private static let allowed = ["AppGroup/Dotted.swift", "Rules/PiProgress.swift", "Components/Atoms.swift", "/Debug/"]

    @Test func 界面源码里没有直接拼的分隔点() throws {
        let app = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let files = try #require(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let file as URL in files where file.pathExtension == "swift" && !file.path.contains("/Tests/") && !Self.allowed.contains(where: file.path.contains) {
            for (index, line) in try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if !code.hasPrefix("//"), code.contains(" · ") || code.contains("Text(\"·\")") {
                    offenders.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "用 Dotted / Dot 代替：\(offenders)")
    }
}
