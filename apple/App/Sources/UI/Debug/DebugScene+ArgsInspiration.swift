#if DEBUG

nonisolated struct InspirationArgs: Decodable, DebugArgGroup {
    static let prefix = "Inspiration"
    /// `-CuePadInspirationArrival <秒>`：先只有图片记录，再模拟下载完成
    let arrival: Double
    /// `-CuePadInspirationAudit <目录>`：每个资源各写自己的创建/删除事件，验收系统消费期间的所有权与结束后的清理
    let audit: String?
    /// `-CuePadInspirationExport <路径>`：把同一分享服务的完整长图写到该路径，供检查屏外内容
    let export: String?
    /// `-CuePadInspirationOriginals YES`：分享取原图副本，核对字节不变
    let originals: Bool
    /// `-CuePadInspirationSource <路径>`：用指定 Markdown 正文复现编辑、墙面摘要和导出
    let source: String?
}
#endif
