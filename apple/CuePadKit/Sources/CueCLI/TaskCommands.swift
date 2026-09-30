import CueStore
import Foundation

extension Command {
  static let task: [Command] = [
    Command(
      path: ["task", "list"], summary: "列出任务（默认只列未完成，按手动顺序）",
      options: [
        .project("只列该项目的任务"), Opt("global", "只列不属于任何项目的任务"), Opt("done", "只列已完成（最近完成在前）"),
        Opt("all", "未完成与已完成都列"),
      ],
      notes: "输出：[Task]。"
    ) { call in
      try call.args.expect()
      let args = call.args
      if args.has("done") && args.has("all") { throw CLIError.usage("--done 与 --all 只能选一个") }
      if args.has("global") && args.value("project") != nil { throw CLIError.usage("--project 与 --global 只能选一个") }
      let project = try await args.value("project").asyncMap { try await call.project($0).id }
      var tasks: [CueTask] = []
      if !args.has("done") { tasks += try await call.store.tasks() }
      if args.has("done") || args.has("all") { tasks += try await call.store.completedTasks() }
      tasks = tasks.filter { (project == nil || $0.projectID == project) && (!args.has("global") || $0.projectID == nil) }
      let views = try await call.taskViews(tasks)
      return listReply(views.map(\.line), json: views.map(\.json))
    },
    Command(
      path: ["task", "add"], summary: "新建任务（放在未完成任务最前）", arguments: "<内容...>",
      options: [.project("挂到该项目；省略则是全局任务")], notes: "内容取所有位置参数，以空格连接。输出：新建的 Task。"
    ) { call in
      guard !call.args.positionals.isEmpty else { throw CLIError.usage("需要 <内容...>") }
      let project = try await call.args.value("project").asyncMap { try await call.project($0).id }
      let task = try await call.store.createTask(call.args.positionals.joined(separator: " "), in: project)
      return reply(try await call.taskViews([task])[0])
    },
    setDone("done", "标记完成", done: true),
    setDone("undo", "撤销完成", done: false),
    Command(
      path: ["task", "edit"], summary: "改任务内容或所属项目", arguments: "<任务> [内容...]",
      options: [.project("改挂到该项目"), Opt("global", "改成全局任务")],
      notes: "内容与项目至少改一项。输出：更新后的 Task。"
    ) { call in
      let args = call.args
      guard let ref = args.positionals.first else { throw CLIError.usage("需要 <任务>") }
      let content = args.positionals.dropFirst().joined(separator: " ")
      if args.has("global") && args.value("project") != nil { throw CLIError.usage("--project 与 --global 只能选一个") }
      guard !content.isEmpty || args.has("global") || args.value("project") != nil else {
        throw CLIError.usage("没有要改的内容：给出新内容，或 --project / --global")
      }
      let task = try await call.task(ref)
      let project = try await args.value("project").asyncMap { try await call.project($0).id }
      let changesProject = args.has("global") || project != nil
      try await call.store.updateTask(task.id) {
        if !content.isEmpty { $0.content = content }
        if changesProject { $0.projectID = project }
      }
      return reply(try await fresh(call, task.id))
    },
    Command(
      path: ["task", "delete"], summary: "永久删除任务", arguments: "<任务>", notes: "输出：{id, deleted: true}。"
    ) { call in
      try call.args.expect("任务")
      let task = try await call.task(call.args.positionals[0])
      try await call.store.deleteTask(task.id)
      let id = task.id.uuidString.lowercased()
      return Reply(text: "已删除 \(id.prefix(8))\n", json: ["id": id, "deleted": true] as JSONObject)
    },
  ]

  private static func setDone(_ verb: String, _ summary: String, done: Bool) -> Command {
    Command(path: ["task", verb], summary: summary, arguments: "<任务>", notes: "输出：更新后的 Task。") { call in
      try call.args.expect("任务")
      let task = try await call.task(call.args.positionals[0])
      let now = Date()
      try await call.store.updateTask(task.id) { $0.completedAt = done ? ($0.completedAt ?? now) : nil }
      return reply(try await fresh(call, task.id))
    }
  }

  private static func fresh(_ call: Call, _ id: UUID) async throws -> TaskView {
    guard let task = try await call.findTask(id) else { throw CLIError.notFound("任务 \(id.uuidString.lowercased()) 已不存在") }
    return try await call.taskViews([task])[0]
  }
}
