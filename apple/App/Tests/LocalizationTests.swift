#if os(macOS)
import Foundation
import Testing

/// 系统控件（工具栏"隐藏边栏"等）按 App 声明的本地化选语言：只声明英文就会一直显示英文。
struct LocalizationTests {
    @Test func App声明简体中文为开发语言并提供该本地化() {
        #expect(Bundle.main.developmentLocalization == "zh-Hans")
        #expect(Bundle.main.localizations.contains("zh-Hans"))
    }
}
#endif
