#if os(macOS)
import CryptoKit
import Foundation
import IOKit

/// 这台 Mac 的稳定标识，取自硬件的 IOPlatformUUID（重装系统、换账号都不变），取哈希前缀而不直接外露原值。
/// Pi 状态记录与投送请求都靠它区分是哪台 Mac，所以必须稳定，不能每次启动随机生成。
nonisolated enum HostIdentity {
    static func hostID(platformUUID: String) -> String {
        "mac-" + SHA256.hash(data: Data(platformUUID.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func current() -> String {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/")
        defer { IOObjectRelease(entry) }
        guard let uuid = IORegistryEntryCreateCFProperty(entry, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        else { preconditionFailure("读不到硬件 UUID（IOPlatformUUID）") }
        return hostID(platformUUID: uuid)
    }
}
#endif
