#if os(macOS)
import AppKit
import ServiceManagement
import SwiftUI

/// 设置里"登录时打开"那一行（`SMAppService.mainApp`，登录项在系统设置里，CuePad 不另装启动代理）：定时与 Cue 值班都要 CuePad 开着。
/// 登录项按 bundle id 记、与正式版共用，不碰真实世界时（`LibraryLocation.touchesRealWorld`）设置里不放这一行。
/// 开关按系统记下的样子：系统设置里还没批准时开关是开的、状态写明，后面链接去登录项；回到 CuePad 时重读一次（在系统设置里改过）。
struct LoginItemRow: View {
    @State private var status = SMAppService.mainApp.status
    @State private var failure: String?

    var body: some View {
        let pending = status == .requiresApproval
        SettingRow(
            title: "登录时打开", icon: Image(.launchAtLogin), tone: failure != nil ? .failure : pending ? .notice : .calm,
            status: (failure ?? (pending ? String(localized: "等你在系统设置里允许") : nil)).map { Dotted($0) },
            help: "定时与 Cue 值班都要 CuePad 开着"
        ) {
            Toggle("登录时打开", isOn: Binding(get: { status == .enabled || pending }, set: set)).labelsHidden().toggleStyle(.switch)
        } fix: {
            if pending { Button("打开系统设置") { SMAppService.openSystemSettingsLoginItems() }.settingFix() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in status = SMAppService.mainApp.status }
    }

    private func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        status = SMAppService.mainApp.status
    }
}
#endif
