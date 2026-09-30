import Foundation

public struct AppInfo: Sendable, Equatable {
    public var pid: pid_t
    public var bundleID: String?
    public var name: String

    public init(pid: pid_t, bundleID: String?, name: String) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
    }
}

public enum TargetSelector: Sendable, Equatable {
    /// 上一个前台应用（不含 CuePad 自身）。
    case lastFrontmost
    case bundleID(String)

    public static let terminal = bundleID("com.apple.Terminal")
    public static let ghostty = bundleID("com.mitchellh.ghostty")
    public static let cursor = bundleID("com.todesktop.230313mzl4w4u92")
}

/// 错误码是稳定的字符串，界面层据此映射文案。
public enum DispatchError: String, Error, Sendable {
    case accessibilityRequired = "ACCESSIBILITY_PERMISSION_REQUIRED"
    case noTarget = "NO_DISPATCH_TARGET"
    case targetUnavailable = "DISPATCH_TARGET_UNAVAILABLE"
    case eventCreateFailed = "CG_EVENT_CREATE_FAILED"
    case clipboardWriteFailed = "CLIPBOARD_WRITE_FAILED"
}

/// 卡片正文按原顺序切成的文字与图片。
public struct Payload: Sendable, Equatable {
    public enum Segment: Sendable, Equatable {
        case text(String)
        /// PNG 字节。
        case image(Data)
    }

    public var segments: [Segment]

    public init(_ segments: [Segment]) { self.segments = segments }
    public init(text: String) { self.init([.text(text)]) }

    /// 只取文字：终端等纯文本目标读到的内容，也是富文本的兜底。
    public var plainText: String {
        segments.reduce(into: "") { result, segment in
            if case .text(let text) = segment { result += text }
        }
    }

    public var hasImages: Bool {
        segments.contains { if case .image = $0 { true } else { false } }
    }
}

public enum Keystroke: Sendable {
    case paste
    case `return`
}

public struct Timing: Sendable {
    public var activationTimeout: Duration
    /// 粘贴后的有界消费窗口：目标处理完 Cmd+V 之前，下一次投送不得改写剪贴板。
    public var pasteSettle: Duration

    public init(activationTimeout: Duration = .seconds(2), pasteSettle: Duration = .milliseconds(100)) {
        self.activationTimeout = activationTimeout
        self.pasteSettle = pasteSettle
    }
}

// MARK: - 接缝：真实实现见 Live*.swift，测试用内存实现

public protocol AppDirectory: Sendable {
    func lastFrontmost() -> AppInfo?
    /// 仍在运行的实例；已退出返回 nil。
    func app(pid: pid_t) -> AppInfo?
    func runningApp(bundleID: String) -> AppInfo?
    func isActive(pid: pid_t) -> Bool
    func activate(pid: pid_t) -> Bool
    /// 同步登记订阅：返回之后发生的激活都不会丢。
    func activations() -> AsyncStream<pid_t>
}

public protocol ClipboardWriting: Sendable {
    /// 写入并回读校验；失败抛 `clipboardWriteFailed`。
    func write(_ payload: Payload) throws(DispatchError)
}

public protocol KeyPosting: Sendable {
    /// 确认能创建事件，避免先改剪贴板再失败。
    func preflight() throws(DispatchError)
    func post(_ key: Keystroke, to pid: pid_t) throws(DispatchError)
}
