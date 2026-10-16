import CueStore
import Foundation

/// 任务是要做的卡片：这里只管任务特有的事（列出、新建、步骤、三态）；正文、移动、回收站用 card 命令。
extension Command {
  static let task: [Command] = [
    Command(
      path: ["task", "list"], summary: "列出任务（默认只列未完成：进行中与待办，按项目分组、组内按层级与手动顺序）",
      options: [
        .project("只列该项目的任务"), .global, .allProjects, Opt("done", "只列已完成（最近完成在前）"),
        Opt("all", "未完成与已完成都列"),
      ],
      notes: Schema.defaultProject(otherwise: "列所有项目的任务") + "\n" + Schema.output("[Card]", Schema.card)
    ) { call in
      try call.args.expect()
      let args = call.args
      if args.has("done") && args.has("all") { throw CLIError.usage("--done 与 --all 只能选一个") }
      let scope = try await call.scope(nullFlag: "global")
      var tasks: [Card] = []
      if !args.has("done") { tasks += try await call.store.tasks(.inProgress, .todo).flatMap(\.tasks) }
      if args.has("done") || args.has("all") { tasks += try await call.store.tasks(.done).flatMap(\.tasks) }
      let views = try await call.cardViews(tasks.filter { scope.contains($0.projectID) })
      return listReply(views.map(\.line), json: views.map(\.json))
    },
    Command(
      path: ["task", "add"], summary: "新建任务（顶层的放在项目最前，步骤放在上级的下级最后）", arguments: "<正文...>",
      options: [
        .project("挂到该项目"), .global,
        Opt("parent", "作为该任务的步骤（项目随它；任务 → 步骤，最多 \(Card.maxTaskDepth) 级）", value: "任务"),
      ],
      notes: Schema.defaultProject(otherwise: "是全局任务") + "；给了 --parent 时不能再给 --project / --global。\n"
        + "正文取所有位置参数，以空格连接：第一行是标题，其余几行是它的正文（开始时连同标题发给 Agent）。已有的灵感用 cuepad card todo 变成任务。\n"
        + Schema.output("新建的 Card", Schema.card)
    ) { call in
      let args = call.args
      guard !args.positionals.isEmpty else { throw CLIError.usage("需要 <正文...>") }
      let body = args.positionals.joined(separator: " ")
      let task: Card
      if let ref = args.value("parent") {
        if args.has("global") || args.value("project") != nil { throw CLIError.usage("--parent 与 --project / --global 只能选一个") }
        task = try await call.store.createTask(body, under: try await call.task(ref).id)
      } else {
        task = try await call.store.createTask(body, in: try await call.scope(nullFlag: "global").target)
      }
      return reply(try await call.cardViews([task])[0])
    },
    setStatus("start", "标记进行中", .inProgress),
    setStatus("done", "标记完成（没完成的步骤一起完成）", .done),
    setStatus("undo", "回到待办（撤销完成或进行中）", .todo),
  ]

  private static func setStatus(_ verb: String, _ summary: String, _ status: TaskStatus) -> Command {
    Command(path: ["task", verb], summary: summary, arguments: "<任务>", notes: Schema.output("更新后的 Card", Schema.card)) { call in
      try call.args.expect("任务")
      let task = try await call.task(call.args.positionals[0])
      try await call.store.setStatus(task.id, status)
      guard let fresh = try await call.store.card(task.id) else { throw CLIError.notFound("任务已不存在") }
      return reply(try await call.cardViews([fresh])[0])
    }
  }
}
