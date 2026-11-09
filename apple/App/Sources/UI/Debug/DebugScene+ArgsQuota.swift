#if DEBUG

/// 额度演示的参数。
/// 键 = `-CuePad` + 前缀「Quota」 + 字段名（大小写不论）；没给：Bool 为 false、数为 0、可选为 nil。
nonisolated struct QuotaArgs: Decodable, DebugArgGroup {
    static let prefix = "Quota"
    /// `-CuePadQuotaFails YES`（配 `-CuePadDemoMac YES`）：演示 Mac 答额度刷新按没查到写回（`runDemoMac`）
    let fails: Bool
    /// `-CuePadQuotaRemindIn <秒>`（配 `-CuePadDemo YES -CuePadNotifications YES` 与空库）：演示额度里 Claude 的本周这么多秒后到提醒时刻（`DemoLibrary.seedQuotas`，核对周额度提醒）
    let remindIn: Double
    /// `-CuePadQuotaResetIn <秒>`：Claude 的 5 小时窗口这么多秒后重置，截图等到重置之后再拍（核对明细在那一刻变成已重置）
    let resetIn: Double
    /// `-CuePadQuotaSample magpie|stress`（配 `-CuePadDemo YES` 与空库）：演示额度换成一处网关报来的账号（`DemoLibrary.seedQuotaSample`）
    let sample: String?
}
#endif
