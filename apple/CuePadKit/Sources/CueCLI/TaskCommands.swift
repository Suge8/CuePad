import CueStore
import Foundation

extension Command {
  static let task: [Command] = [
    Command(
      path: ["task", "list"], summary: "列出任务（默认只列未完成：进行中与待办，按项目分组、组内手动顺序）",
      options: [
        .project("只列该项目的任务"), .global, .allProjects, Opt("done", "只列已完成（最近完成在前）"),
        Opt("all", "未完成与已完成都列"),
      ],
      notes: Schema.defaultProject(otherwise: "列所有项目的任务") + "\n" + Schema.output("[Task]", Schema.task)
    ) { call in
      try call.args.expect()
      let args = call.args
      if args.has("done") && args.has("all") { throw CLIError.usage("--done 与 --all 只能选一个") }
      let scope = try await call.scope(nullFlag: "global")
      var tasks: [CueTask] = []
      if !args.has("done") { tasks += try await call.allTasks([.inProgress, .todo]) }
      if args.has("done") || args.has("all") { tasks += try await call.allTasks([.done]) }
      tasks = tasks.filter { scope.contains($0.projectID) }
      let views = try await call.taskViews(tasks)
      return listReply(views.map(\.line), json: views.map(\.json))
    },
    Command(
      path: ["task", "add"], summary: "新建任务（顶层的放在未完成任务最前，子任务放在上级的子任务最后）", arguments: "<内容...>",
      options: [
        .project("挂到该项目"), .global,
        Opt("parent", "作为该任务的子任务（项目随它；任务 → 子任务 → 子任务，最多 \(CueTask.maxDepth) 级）", value: "任务"),
      ],
      notes: Schema.defaultProject(otherwise: "是全局任务") + "；给了 --parent 时不能再给 --project / --global。\n内容取所有位置参数，以空格连接。\n"
        + Schema.output("新建的 Task", Schema.task)
    ) { call in
      let args = call.args
      guard !args.positionals.isEmpty else { throw CLIError.usage("需要 <内容...>") }
      let content = args.positionals.joined(separator: " ")
      let task: CueTask
      if let ref = args.value("parent") {
        if args.has("global") || args.value("project") != nil { throw CLIError.usage("--parent 与 --project / --global 只能选一个") }
        task = try await call.store.createTask(content, under: try await call.task(ref).id)
      } else {
        task = try await call.store.createTask(content, in: try await call.scope(nullFlag: "global").target)
      }
      return reply(try await call.taskViews([task])[0])
    },
    setStatus("start", "标记进行中", .inProgress),
    setStatus("done", "标记完成", .done),
    setStatus("undo", "回到待办（撤销完成或进行中）", .todo),
    Command(
      path: ["task", "edit"], summary: "改任务内容或所属项目", arguments: "<任务> [内容...]",
      options: [.project("改挂到该项目"), Opt("global", "改成全局任务")],
      notes: "内容与项目至少改一项。\n" + Schema.output("更新后的 Task", Schema.task)
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
      path: ["task", "delete"], summary: "永久删除任务", arguments: "<任务>", notes: "输出（--json）：{id, deleted: true}"
    ) { call in
      try call.args.expect("任务")
      let task = try await call.task(call.args.positionals[0])
      try await call.store.deleteTask(task.id)
      let id = task.id.uuidString.lowercased()
      return Reply(text: "已删除 \(id.prefix(8))\n", json: ["id": id, "deleted": true] as JSONObject)
    },
  ]

  private static func setStatus(_ verb: String, _ summary: String, _ status: TaskStatus) -> Command {
    Command(path: ["task", verb], summary: summary, arguments: "<任务>", notes: Schema.output("更新后的 Task", Schema.task)) { call in
      try call.args.expect("任务")
      let task = try await call.task(call.args.positionals[0])
      try await call.store.updateTask(task.id) { $0.status = status }
      return reply(try await fresh(call, task.id))
    }
  }

  private static func fresh(_ call: Call, _ id: UUID) async throws -> TaskView {
    guard let task = try await call.findTask(id) else { throw CLIError.notFound("任务 \(id.uuidString.lowercased()) 已不存在") }
    return try await call.taskViews([task])[0]
  }
}
