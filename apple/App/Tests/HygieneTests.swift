#if os(macOS)
import Foundation
import Testing
@testable import CuePad

/// 测试不能在用户机器上留文件：偏好套件放进临时目录，释放后目录连同偏好一起消失。
@MainActor
struct HygieneTests {
    @Test func Rig的偏好与目录随释放一起删除_不进系统偏好目录() throws {
        var directory: URL
        do {
            let rig = Rig()
            directory = rig.directory
            rig.services.settings.theme = .dark
            #expect(rig.suite.hasPrefix(rig.directory.path), "偏好套件不在临时目录里：\(rig.suite)")
            #expect(rig.defaults.string(forKey: "theme") == "dark")
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
#endif
