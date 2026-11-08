import Foundation

extension CueStore {
  /// 只收集本事务里改变收尾资格的事实，不保存生命周期状态：本地操作、同步、层级修复共用入口。
  /// 正文与计时刷新不触发收尾；纯关联不产生结束；已完成后主动恢复的会话不因再次归档而关闭。
  /// 临时表随事务回滚，提交前消费；结束资格仍只由 taskSessionCanEnd 决定。
  static let taskSessionEvents = """
    CREATE TEMP TABLE taskSessionEvents (kind TEXT NOT NULL, id TEXT NOT NULL, PRIMARY KEY(kind, id));
    CREATE TEMP TRIGGER taskSessionCardInserted AFTER INSERT ON main.cards
    WHEN NEW.todoAt IS NOT NULL
    BEGIN INSERT OR IGNORE INTO taskSessionEvents VALUES ('task', NEW.id); END;
    CREATE TEMP TRIGGER taskSessionCardClosed AFTER UPDATE OF completedAt, archivedAt, deletedAt ON main.cards
    WHEN NEW.todoAt IS NOT NULL AND OLD.completedAt IS NULL AND (
      NEW.completedAt IS NOT NULL OR (OLD.archivedAt IS NULL AND NEW.archivedAt IS NOT NULL)
      OR (OLD.deletedAt IS NULL AND NEW.deletedAt IS NOT NULL))
    BEGIN INSERT OR IGNORE INTO taskSessionEvents VALUES ('task', NEW.id); END;
    CREATE TEMP TRIGGER taskSessionStructureChanged AFTER UPDATE OF parentID, projectID, sortKey ON main.cards
    WHEN NEW.todoAt IS NOT NULL AND (OLD.parentID IS NOT NEW.parentID OR OLD.projectID IS NOT NEW.projectID OR OLD.sortKey IS NOT NEW.sortKey)
    BEGIN
      INSERT OR IGNORE INTO taskSessionEvents VALUES ('task', NEW.id);
      INSERT OR IGNORE INTO taskSessionEvents SELECT 'task', OLD.parentID WHERE OLD.parentID IS NOT NULL;
    END;
    CREATE TEMP TRIGGER taskSessionProjectInserted AFTER INSERT ON main.projects
    WHEN NEW.deletedAt IS NOT NULL
    BEGIN
      INSERT OR IGNORE INTO taskSessionEvents SELECT 'task', id FROM cards
        WHERE projectID = NEW.id AND todoAt IS NOT NULL AND completedAt IS NULL;
    END;
    CREATE TEMP TRIGGER taskSessionProjectClosed AFTER UPDATE OF deletedAt ON main.projects
    WHEN OLD.deletedAt IS NULL AND NEW.deletedAt IS NOT NULL
    BEGIN
      INSERT OR IGNORE INTO taskSessionEvents SELECT 'task', id FROM cards
        WHERE projectID = NEW.id AND todoAt IS NOT NULL AND completedAt IS NULL;
    END;
    CREATE TEMP TRIGGER taskSessionSourceInserted AFTER INSERT ON main.piSessionStates
    WHEN NEW.createdForTaskID IS NOT NULL
    BEGIN INSERT OR IGNORE INTO taskSessionEvents VALUES ('task', NEW.createdForTaskID); END;
    CREATE TEMP TRIGGER taskSessionSourceChanged AFTER UPDATE OF createdForTaskID, hosted, agent ON main.piSessionStates
    WHEN NEW.createdForTaskID IS NOT NULL AND (
      OLD.createdForTaskID IS NOT NEW.createdForTaskID OR OLD.hosted IS NOT NEW.hosted OR OLD.agent IS NOT NEW.agent)
    BEGIN INSERT OR IGNORE INTO taskSessionEvents VALUES ('task', NEW.createdForTaskID); END;
    CREATE TEMP TRIGGER sessionEndInserted AFTER INSERT ON main.piSessionStates
    WHEN NEW.state = 'ended'
    BEGIN INSERT OR IGNORE INTO taskSessionEvents VALUES ('receipt', NEW.sessionID); END;
    CREATE TEMP TRIGGER sessionEndChanged AFTER UPDATE OF state, stateSince ON main.piSessionStates
    WHEN NEW.state = 'ended'
    BEGIN INSERT OR IGNORE INTO taskSessionEvents VALUES ('receipt', NEW.sessionID); END;
    CREATE TEMP TRIGGER endRequestInserted AFTER INSERT ON main.deliveryRequests
    WHEN NEW.mode = 'end' AND NEW.targetRef IS NOT NULL
    BEGIN INSERT OR IGNORE INTO taskSessionEvents VALUES ('receipt', NEW.targetRef); END;
    CREATE TEMP TRIGGER endRequestChanged AFTER UPDATE OF status ON main.deliveryRequests
    WHEN NEW.mode = 'end' AND NEW.targetRef IS NOT NULL AND OLD.status IS NOT NEW.status
    BEGIN INSERT OR IGNORE INTO taskSessionEvents VALUES ('receipt', NEW.targetRef); END;
    """

  func reconcileTaskSessionEvents() throws {
    let tasks = try db.query("SELECT id FROM taskSessionEvents WHERE kind = 'task'") { $0.uuid(0) }
    for task in tasks { try endUnusedSessions(of: task, cue: false) }
    let sessions = try db.query("SELECT id FROM taskSessionEvents WHERE kind = 'receipt'") { $0.text(0) }
    for session in sessions { try confirmSessionEnd(session) }
    try db.run("DELETE FROM taskSessionEvents")
  }
}
