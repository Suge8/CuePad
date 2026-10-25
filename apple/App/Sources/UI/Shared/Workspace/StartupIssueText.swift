/// 启动时没完成的事给人看的一句话（Mac 侧栏与 iOS 设置共用）：说清哪件事没成、会不会自己重试或怎么处理，后面附原因。
extension AppServices.StartupIssue {
    var text: String {
        switch self {
        case .globalShortcutUnavailable(let detail): String(localized: "全局快捷键没能注册，可在设置里换一个：\(detail)")
        case .captureImportFailed(let detail): String(localized: "分享进来的内容没能存成灵感，下次会重试：\(detail)")
        case .widgetDataUnavailable(let detail): String(localized: "小组件数据没能更新：\(detail)")
        case .syncUnavailable(let detail): String(localized: "iCloud 同步出了问题：\(detail)")
        #if os(macOS)
        case .piBridgeUnavailable(let detail): String(localized: "Agent 连接不可用：\(detail)")
        case .piHistoryUnavailable(let detail): String(localized: "Agent 历史索引出错：\(detail)")
        #endif
        }
    }
}
