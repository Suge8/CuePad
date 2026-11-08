import Foundation
#if os(iOS)
import UIKit
#endif

/// 语言由系统选择；这里仅展示当前进程实际使用的语言，并提供系统入口，不写语言偏好。
enum AppLanguage {
    static var name: String {
        let code = Bundle.main.preferredLocalizations.first ?? Bundle.main.developmentLocalization ?? "en"
        return Locale(identifier: code).localizedString(forIdentifier: code) ?? code
    }

    #if os(macOS)
    // 系统 Localization 设置扩展声明支持此 URL；只开语言与地区页，不指定应用或修改设置。
    static let settings = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!
    #else
    static let settings = URL(string: UIApplication.openSettingsURLString)!
    #endif
}
