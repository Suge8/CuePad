extension Schema {
  /// 自动收尾按创建任务找会话，来源未知的历史会话不占这个索引。
  static let taskOriginIndex = "CREATE INDEX piSessionStates_createdForTaskID ON piSessionStates(createdForTaskID) WHERE createdForTaskID IS NOT NULL;"

  /// 93：任务开始变成自身事实，旧父任务在升级时一次补齐；关联修订与会话创建来源同步保存。
  /// 来源不从可清理的请求或发送记录猜测，旧会话默认不授权自动收尾。
  static let taskSessionUpgrade: Upgrade = """
    ALTER TABLE cards ADD COLUMN sessionBindingRevision TEXT;
    ALTER TABLE deliveryRequests ADD COLUMN sessionBindingRevision TEXT;
    ALTER TABLE piSessionStates ADD COLUMN createdForTaskID TEXT;
    \(taskOriginIndex)
    UPDATE cards SET startedAt = (
      SELECT MIN(COALESCE(s.startedAt, s.completedAt)) FROM cards s
      WHERE s.parentID = cards.id AND s.todoAt IS NOT NULL AND s.deletedAt IS NULL), modifiedAt = modifiedAt + 1
    WHERE todoAt IS NOT NULL AND startedAt IS NULL AND EXISTS (
      SELECT 1 FROM cards s WHERE s.parentID = cards.id AND s.todoAt IS NOT NULL AND s.deletedAt IS NULL
        AND (s.startedAt IS NOT NULL OR s.completedAt IS NOT NULL));
    """
}
