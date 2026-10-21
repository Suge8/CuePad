extension AppServices {
    nonisolated enum StartupIssue: Equatable {
        case globalShortcutUnavailable(String)
        /// 分享扩展留下的内容没能入库（保留在共享容器里，下次再试）。
        case captureImportFailed(String)
        /// iCloud 同步（或依赖它的 Mac 端远程功能）没能启动。
        case syncUnavailable(String)
        case widgetDataUnavailable(String)
        #if os(macOS)
        case piBridgeUnavailable(String)
        /// Pi 历史索引读写 Store 失败；该会话文件不再写回。
        case piHistoryUnavailable(String)
        #endif
    }
}
