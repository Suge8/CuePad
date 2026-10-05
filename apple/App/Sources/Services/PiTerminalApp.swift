import Foundation

/// 继续会话、开新会话时打开 Pi 的终端。设置里只列本机装了的（`installed`），默认 Terminal。
enum PiTerminalApp: String, CaseIterable, Sendable {
    case terminal, ghostty, iterm, warp

    var label: String {
        switch self {
        case .terminal: "终端"
        case .ghostty: "Ghostty"
        case .iterm: "iTerm"
        case .warp: "Warp"
        }
    }

    var bundleID: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .ghostty: "com.mitchellh.ghostty"
        case .iterm: "com.googlecode.iterm2"
        case .warp: "dev.warp.Warp-Stable"
        }
    }
}

#if os(macOS)
import AppKit

extension PiTerminalApp {
    /// 本机装了的终端（系统自带的终端总在）。
    static func installed(in workspace: NSWorkspace = .shared) -> [PiTerminalApp] {
        allCases.filter { $0 == .terminal || workspace.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }
}
#endif
