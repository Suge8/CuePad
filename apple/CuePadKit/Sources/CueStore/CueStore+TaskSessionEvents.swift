import Foundation

extension CueStore {
  /// 只收集本事务里改变收尾资格的事实，不保存生命周期状态：本地操作、同步、层级修复共用入口。
  /// 正文与计时刷新不触发收尾；纯关联不产生结束；已完成后主动恢复的会话不因再次归档而关闭。
  /// 临时表随事务回滚，提交前消费；结束资格仍只由 taskSessionCanEnd 决定。
  static let taskSessionEvents = """
    CREATE TEMP TABLE taskSessionEvents (id TEXT PRIMARY KEY NOT NULL);
    CREATE TEMP TRIGGER taskSessionCardInserted AFTER INSERT ON main.cards
    WHEN NEW.todoAt IS NOT NULL
    BEGIN INSERT OR IGNORE INTO taskSessionEvents VALUES (NEW.id); END;
    CREATE TEMP TRIGGER taskSessionCardClosed AFTER UPDATE OF completedAt, archivedAt, deletedAt ON main.cards
    WHEN NEW.todoAt IS NOT NULL AND OLD.completedAt IS NULL AND (
      NEW.completedAt IS NOT NULL OR (OLD.archivedAt IS NULL AND NEW.archivedAt IS NOT NULL)
      OR (OLD.deletedAt IS NULL AND NEW.deletedAt IS NOT NULL))
    BEGIN INSERT OR IGNORE INTO taskSessionEvents VALUES (NEW.id); END;
    CREATE TEMP TRIGGER taskSessionStructureChanged AFTER UPDATE OF parentID, projectID, sortKey ON main.cards
    WHEN NEW.todoAt IS NOT NULL AND (OLD.parentID IS NOT NEW.parentID OR OLD.projectID IS NOT NEW.projectID OR OLD.sortKey IS NOT NEW.sortKey)
    BEGIN
      INSERT OR IGNORE INTO taskSessionEvents VALUES (NEW.id);
      INSERT OR IGNORE INTO taskSessionEvents SELECT OLD.parentID WHERE OLD.parentID IS NOT NULL;
    END;
    CREATE TEMP TRIGGER taskSessionProjectInserted AFTER INSERT ON main.projects
    WHEN NEW.deletedAt IS NOT NULL
    BEGIN
      INSERT OR IGNORE INTO taskSessionEvents SELECT id FROM cards
        WHERE projectID = NEW.id AND todoAt IS NOT NULL AND completedAt IS NULL;
    END;
    CREATE TEMP TRIGGER taskSessionProjectClosed AFTER UPDATE OF deletedAt ON main.projects
    WHEN OLD.deletedAt IS NULL AND NEW.deletedAt IS NOT NULL
    BEGIN
      INSERT OR IGNORE INTO taskSessionEvents SELECT id FROM cards
        WHERE projectID = NEW.id AND todoAt IS NOT NULL AND completedAt IS NULL;
    END;
    CREATE TEMP TRIGGER taskSessionSourceInserted AFTER INSERT ON main.piSessionStates
    WHEN NEW.createdForTaskID IS NOT NULL
    BEGIN INSERT OR IGNORE INTO taskSessionEvents VALUES (NEW.createdForTaskID); END;
    CREATE TEMP TRIGGER taskSessionSourceChanged AFTER UPDATE OF createdForTaskID, hosted, agent ON main.piSessionStates
    WHEN NEW.createdForTaskID IS NOT NULL AND (
      OLD.createdForTaskID IS NOT NEW.createdForTaskID OR OLD.hosted IS NOT NEW.hosted OR OLD.agent IS NOT NEW.agent)
    BEGIN INSERT OR IGNORE INTO taskSessionEvents VALUES (NEW.createdForTaskID); END;
    CREATE TEMP TRIGGER sessionUseReleased AFTER UPDATE OF status, mode, targetRef ON main.deliveryRequests
    WHEN OLD.targetRef IS NOT NULL AND OLD.mode IN (\(sqlList(DeliveryMode.toSession))) AND OLD.status IN (\(DeliveryStatus.openSQL))
      AND (NEW.status NOT IN (\(DeliveryStatus.openSQL)) OR NEW.mode NOT IN (\(sqlList(DeliveryMode.toSession))) OR OLD.targetRef IS NOT NEW.targetRef)
    BEGIN
      \(releasedHold)
    END;
    CREATE TEMP TRIGGER sessionUseRemoved AFTER DELETE ON main.deliveryRequests
    WHEN OLD.targetRef IS NOT NULL AND OLD.mode IN (\(sqlList(DeliveryMode.toSession))) AND OLD.status IN (\(DeliveryStatus.openSQL))
    BEGIN
      \(releasedHold)
    END;
    """

  /// 投送释放占用时（`OLD` 是那条投送）补上被它挡下的收尾。只认任务还在看板上时写下的话：用这个会话的任务里有一件还在，或在它写下之后才离开。
  /// 都离开之后才写的，是你接着用一个收尾过的会话，送完不再结束它：否则恢复起来的会话每句话都在刚开跑时被停下。
  private static let releasedHold = """
    INSERT OR IGNORE INTO taskSessionEvents SELECT s.createdForTaskID FROM piSessionStates s
      WHERE s.sessionID = OLD.targetRef AND s.createdForTaskID IS NOT NULL AND EXISTS (
        SELECT 1 FROM cards c WHERE (c.id = s.createdForTaskID OR c.piSessionID = s.sessionID)
          AND MIN(COALESCE(c.completedAt, \(Int64.max)), COALESCE(c.archivedAt, \(Int64.max)), COALESCE(c.deletedAt, \(Int64.max))) >= OLD.createdAt);
    """

  func reconcileTaskSessionEvents() throws {
    let tasks = try db.query("SELECT id FROM taskSessionEvents") { $0.uuid(0) }
    for task in tasks { try endUnusedSessions(of: task, cue: false) }
    try db.run("DELETE FROM taskSessionEvents")
  }
}
