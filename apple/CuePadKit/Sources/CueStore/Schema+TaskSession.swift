extension Schema {
  /// 自动收尾按创建任务找会话，来源未知的历史会话不占这个索引。
  static let taskOriginIndex = "CREATE INDEX piSessionStates_createdForTaskID ON piSessionStates(createdForTaskID) WHERE createdForTaskID IS NOT NULL;"

  /// 93：任务开始变成自身事实，旧父任务在升级时一次补齐；关联修订与会话创建来源同步保存。
  /// 来源不从可清理的请求或发送记录猜测，旧会话默认不授权自动收尾。
  /// 旧交接按请求身份补第 0 代关联修订，各端升级得到相同值；卡片只授权最后一次交接，之后的明确关联从第 1 代开始。
  static let taskSessionUpgrade: Upgrade = """
    ALTER TABLE cards ADD COLUMN sessionBindingRevision TEXT;
    ALTER TABLE deliveryRequests ADD COLUMN sessionBindingRevision TEXT;
    ALTER TABLE piSessionStates ADD COLUMN createdForTaskID TEXT;
    \(taskOriginIndex)
    UPDATE deliveryRequests
    SET sessionBindingRevision = json_object('explicit', json('false'), 'generation', 0, 'id', upper(id)), modifiedAt = modifiedAt + 1
    WHERE cardID IS NOT NULL AND mode IN ('start', 'send', 'command');
    UPDATE cards SET sessionBindingRevision = (
      SELECT r.sessionBindingRevision FROM deliveryRequests r WHERE r.cardID = cards.id ORDER BY r.createdAt DESC, r.id DESC LIMIT 1),
      modifiedAt = modifiedAt + 1
    WHERE EXISTS (SELECT 1 FROM deliveryRequests r WHERE r.cardID = cards.id AND r.sessionBindingRevision IS NOT NULL);
    UPDATE cards SET startedAt = (
      SELECT MIN(COALESCE(s.startedAt, s.completedAt)) FROM cards s
      WHERE s.parentID = cards.id AND s.todoAt IS NOT NULL AND s.deletedAt IS NULL), modifiedAt = modifiedAt + 1
    WHERE todoAt IS NOT NULL AND startedAt IS NULL AND EXISTS (
      SELECT 1 FROM cards s WHERE s.parentID = cards.id AND s.todoAt IS NOT NULL AND s.deletedAt IS NULL
        AND (s.startedAt IS NOT NULL OR s.completedAt IS NOT NULL));
    """

  /// 94：只给关联意图增加兑现进展；旧端会忽略它并覆盖 ACK，因此同时抬最低对端版本。
  static let taskSessionFulfillmentUpgrade: Upgrade = """
    UPDATE cards SET sessionBindingRevision = json_set(sessionBindingRevision, '$.fulfilled', json(CASE
      WHEN json_extract(sessionBindingRevision, '$.explicit') = 1 OR (piSessionID IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM deliveryRequests r WHERE json_extract(r.sessionBindingRevision, '$.id') = json_extract(cards.sessionBindingRevision, '$.id')
          AND NOT (r.targetRef IS cards.piSessionID OR (r.mode = 'start' AND EXISTS (
            SELECT 1 FROM piSessionStates s WHERE s.sessionID = cards.piSessionID AND s.launchToken = \(CueStore.launchToken("r")))))))
      THEN 'true' ELSE 'false' END)), modifiedAt = modifiedAt + 1
    WHERE sessionBindingRevision IS NOT NULL;
    UPDATE deliveryRequests SET sessionBindingRevision = json_set(sessionBindingRevision, '$.fulfilled', json('false')), modifiedAt = modifiedAt + 1
    WHERE sessionBindingRevision IS NOT NULL;
    """
}
