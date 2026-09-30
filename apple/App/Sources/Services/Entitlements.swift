import Foundation
#if os(macOS)
import Security
#endif

/// 本进程实际带着的权限（来自代码签名，不是权限文件里写了什么）。
nonisolated enum Entitlements {
    /// macOS：读自己的签名；iOS：权限由系统在安装时校验，能运行就说明有。
    static var hasCloudKit: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) != nil
        #else
        true
        #endif
    }
}
