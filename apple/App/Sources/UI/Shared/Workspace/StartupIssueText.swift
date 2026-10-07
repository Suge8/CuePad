/// 启动时没完成的事给人看的一句话（Mac 侧栏与 iOS 设置共用）：说清哪件事没成、会不会自己重试或怎么处理，后面附原因。
extension AppServices.StartupIssue {
    var text: String {
        switch self {
        case .legacyImportFailed(let detail): "导入旧版数据失败，下次启动会重试：\(detail)"
        case .globalShortcutUnavailable(let detail): "全局快捷键没能注册，可在设置里换一个：\(detail)"
        case .captureImportFailed(let detail): "分享进来的内容没能存成灵感，下次会重试：\(detail)"
        case .widgetDataUnavailable(let detail): "小组件数据没能更新：\(detail)"
        case .syncUnavailable(let detail): "iCloud 同步出了问题：\(detail)"
        #if os(macOS)
        case .piBridgeUnavailable(let detail): "Agent 连接不可用：\(detail)"
        case .piHistoryUnavailable(let detail): "Agent 历史索引出错：\(detail)"
        #endif
        }
    }
}
