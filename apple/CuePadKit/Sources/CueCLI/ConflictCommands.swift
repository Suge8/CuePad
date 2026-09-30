import CueStore
import Foundation

extension Command {
  static let conflicts: [Command] = [
    Command(
      path: ["conflicts", "list"], summary: "列出待处理的正文冲突（两台设备离线并发编辑同一张卡）",
      notes: "输出：[Conflict]，Conflict.original 是原卡（较新版本），Conflict.copy 是冲突副本（较旧正文）；最近产生的在前。"
    ) { call in
      try call.args.expect()
      var lines: [String] = []
      var json: [JSONObject] = []
      for conflict in try await call.store.conflicts() {
        let views = try await call.cardViews([conflict.original, conflict.copy])
        lines += ["副本 \(views[1].line)", "原卡 \(views[0].line)"]
        json.append(["original": views[0].json, "copy": views[1].json])
      }
      return listReply(lines, json: json)
    },
    Command(
      path: ["conflicts", "resolve"], summary: "选定保留的版本，删除副本", arguments: "<副本>",
      options: [Opt("keep", "original（保留原卡正文）或 copy（用副本正文替换原卡）", value: "版本")],
      notes: "<副本> 是 conflicts list 里 copy 的 id。输出：{resolved: 副本 id, kept, card: 保留下来的 Card}。"
    ) { call in
      try call.args.expect("副本")
      guard let choice = call.args.value("keep") else { throw CLIError.usage("需要 --keep original|copy") }
      guard let keep = ["original": ConflictChoice.original, "copy": .copy][choice] else {
        throw CLIError.usage("--keep 只能是 original 或 copy，收到「\(choice)」")
      }
      let copy = try await call.card(call.args.positionals[0])
      try await call.store.resolveConflict(copy: copy.id, keep: keep)
      // 原卡已不存在时 Store 保留副本（转为普通卡）。
      var survivor = try await call.store.card(copy.id)
      if survivor == nil, let original = copy.conflictOf { survivor = try await call.store.card(original) }
      guard let survivor else { throw CLIError.notFound("卡片已不存在") }
      let view = try await call.cardViews([survivor])[0]
      let json: JSONObject = ["resolved": copy.id.uuidString.lowercased(), "kept": choice, "card": view.json]
      return Reply(text: "已保留\(choice == "original" ? "原卡" : "副本")正文：\(view.line)\n", json: json)
    },
  ]
}
