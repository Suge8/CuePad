#if DEBUG

nonisolated struct QuotaArgs: Decodable, DebugArgGroup {
    static let prefix = "Quota"
    #if os(iOS)
    /// `-CuePadQuotaFails YES`（仅手机，配 `-CuePadDemoMac YES`）：演示 Mac 答额度刷新按没查到写回。Mac 查额度直接问本机会话、不发请求，没有演示 Mac 可答
    let fails: Bool
    #endif
    /// `-CuePadQuotaRemindIn <秒>`（配 `-CuePadDemo YES -CuePadNotifications YES` 与空库）：演示额度里 Claude 的本周这么多秒后到提醒时刻，核对周额度提醒
    let remindIn: Double
    /// `-CuePadQuotaResetIn <秒>`：Claude 的 5 小时窗口这么多秒后重置，截图等到重置之后再拍（核对明细在那一刻变成已重置）
    let resetIn: Double
}
#endif
