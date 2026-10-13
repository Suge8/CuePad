#if os(macOS)
import AppKit
#else
import ObjectiveC
import UIKit
#endif

/// 输入框原样收字：写给 Agent 的话里常有命令行参数与代码，`--flag` 不能被换成破折号、直引号不能换成弯引号、也不做文本替换
/// （编辑器 `CueTextView` / `iOSCueTextView` 同一条规则）。App 里的输入框大多是 SwiftUI 的 `TextField`，拿不到底下的系统视图，
/// 所以进程启动时一处关掉，覆盖全部输入框（输入框、会话回复框、随手记、搜索、任务标题、记忆、对话框里的输入）。
enum LiteralText {
    #if os(macOS)
    /// 系统文本视图（含 SwiftUI 输入框共用的字段编辑器）建出时按这几个偏好定初值。写进参数域：只在内存、优先级最高，
    /// 系统设置里开着"智能引号与破折号"也盖得住，又不写进偏好域。
    static func install() {
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        for key in ["NSAutomaticDashSubstitutionEnabled", "NSAutomaticQuoteSubstitutionEnabled", "NSAutomaticTextReplacementEnabled"] {
            arguments[key] = false
        }
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
    #else
    /// UIKit 的智能破折号与引号默认跟着键盘设置走，没有全局偏好：把输入框（单行是 `UITextField`，多行与回复框是 `UITextView`）
    /// 这两项的取值换成"关"。只换取值，设置照常存。
    static func install() {
        for type in [UITextField.self, UITextView.self] as [AnyClass] {
            replace(type, "smartDashesType", UITextSmartDashesType.no.rawValue)
            replace(type, "smartQuotesType", UITextSmartQuotesType.no.rawValue)
        }
    }

    private static func replace(_ type: AnyClass, _ getter: String, _ value: Int) {
        let selector = NSSelectorFromString(getter)
        guard let method = class_getInstanceMethod(type, selector) else { preconditionFailure("\(type) 没有 \(getter)") }
        let block: @convention(block) (AnyObject) -> Int = { _ in value }
        class_replaceMethod(type, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
    }
    #endif
}
