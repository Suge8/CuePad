#if os(macOS)
import Foundation
import Testing
@testable import CuePad

/// Sparkle 自动更新：配置写在真实构建的 Info.plist 里，界面只经 `UpdateService` 操作更新器。
@MainActor
struct UpdateTests {
    @Test func 真实构建里带着更新源地址与EdDSA公钥() throws {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["SUFeedURL"] as? String == "https://cue-pad.com/appcast.xml")
        let key = try #require(info["SUPublicEDKey"] as? String, "缺少 SUPublicEDKey")
        #expect(Data(base64Encoded: key)?.count == 32, "EdDSA 公钥应是 32 字节的 base64")
        #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
    }

    @Test func Sparkle框架随App嵌入() {
        let framework = Bundle.main.privateFrameworksURL?.appending(path: "Sparkle.framework")
        #expect(framework.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }
}
#endif
