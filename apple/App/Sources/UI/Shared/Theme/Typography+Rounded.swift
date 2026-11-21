import CoreText
import CueStore
import OSLog
import SwiftUI

/// 界面字（栏头、侧栏、卡片、列表、按钮、看板、设置、提示）用圆体-简，中西文都是它的字形；Agent 的回答、输入框、代码与改动仍是系统字体
/// （`Typography` 里不经 `ui` 的那几档）：长文用圆体读着累。界面不是中文、或圆体-简还没取到时用系统圆体（SF Rounded），英文配圆体-简的西文字形显得糙。
/// 圆体-简只有常规与粗两档：中、半粗、粗都落到它的粗（调用处的 `.weight()` 同样就近取），层级靠字号与墨色分；它也没有等宽数字，`.monospacedDigit()` 对它不起作用。
/// 否决过：西文与数字配 SF Rounded、中文垫圆体-简——SwiftUI 的 `Font` 没有回退表，要从平台字体建（`Font(CTFont)`），
/// 调用处的 `.weight()` 对它不起作用（约 120 处），iOS 也丢了动态字体。
extension Typography {
    #if os(macOS)
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        RoundedFace.ready ? .custom(RoundedFace.name, size: size).weight(weight) : .system(size: size, weight: weight, design: .rounded)
    }
    #else
    static func ui(_ style: Font.TextStyle, _ weight: Font.Weight = .regular) -> Font {
        RoundedFace.ready
            ? .custom(RoundedFace.name, size: RoundedFace.size(style), relativeTo: style).weight(weight)
            : .system(style, design: .rounded, weight: weight)
    }
    #endif
}

/// 圆体-简随系统给、不预装，也不许打进包里（TN3214：苹果设计或授权的字体经系统取用）。启动时定一次用不用，用到一半整屏的字换一遍会跳：
/// Mac 上系统自己激活；iOS 上每次启动都要向系统再要一遍才认得出（要一遍约 110ms，不能卡在启动上），所以记下它的文件、下次启动直接登记（约 1ms）。
/// 头一次没有就向系统要，这一次先用系统字体，下次启动起用上。
enum RoundedFace {
    nonisolated static let name = "STYuanti-SC-Regular"
    private nonisolated static let bold = "STYuanti-SC-Bold"
    private nonisolated static let fileKey = "RoundedFaceFile"

    static let ready: Bool = {
        guard Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true else { return false }
        if installed { return true }
        if let path = UserDefaults.standard.string(forKey: fileKey) {
            CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: path) as CFURL, .process, nil)
            if installed { return true }
        }
        // 要字体可能堵住调用的线程（见 `installed`），不在主线程上要
        DispatchQueue.global(qos: .utility).async { fetch() }
        return false
    }()

    /// Mac 上只查系统已有的字体名单，不按名字建一个来试：机器上没有这款时系统当场去取，取不到就一直堵着调用的线程，而头一次问是在主线程画界面时——
    /// GitHub 的 runner 没有圆体-简，挂真窗口的测试堵满 120 秒的时限（运行 44678051442 的日志停在这一步）。iOS 上按名字试没卡过，照旧。
    private nonisolated static var installed: Bool {
        #if os(macOS)
        let available = Set(CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? [])
        return [name, bold].allSatisfy(available.contains)
        #else
        return [name, bold].allSatisfy { CTFontCopyPostScriptName(CTFontCreateWithName($0 as CFString, 0, nil)) as String == $0 }
        #endif
    }

    private nonisolated static func fetch() {
        let wanted = [name, bold].map { CTFontDescriptorCreateWithNameAndSize($0 as CFString, 0) } as CFArray
        CTFontDescriptorMatchFontDescriptorsWithProgressHandler(wanted, nil) { @Sendable state, progress in
            switch state {
            case .didFailWithError:
                let error = (progress as NSDictionary)[kCTFontDescriptorMatchingError]
                Logger(subsystem: AppIdentity.id, category: "font").error("圆体-简没下载下来：\(String(describing: error), privacy: .public)")
            case .didFinish:
                if let file = CTFontCopyAttribute(CTFontCreateWithName(name as CFString, 0, nil), kCTFontURLAttribute) as? URL {
                    UserDefaults.standard.set(file.path, forKey: fileKey)
                }
            default: break
            }
            return true
        }
    }

    #if os(iOS)
    static func size(_ style: Font.TextStyle) -> CGFloat {
        let ui: UIFont.TextStyle = switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
        return UIFont.preferredFont(forTextStyle: ui, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
    }
    #endif
}
