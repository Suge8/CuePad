import CueStore
import Foundation

extension Command {
  static let show = Command(
    path: ["show"], summary: "把文件发到手机上预览：挂在某个 Agent（Pi）会话的对话里，手机上点预览卡查看", arguments: "<文件>",
    options: [
      Opt("session", "Pi 会话 id（必填；Pi 里 /session 显示的那个）", value: "会话"),
      Opt("title", "一句标题，说明这是什么（默认用文件名）", value: "标题"),
    ],
    notes: """
      可发：\(PiPreviewKind.supportedList)；单个文件不超过 \(PiPreview.maxBytes / 1_000_000) MB。
      HTML 在手机上只读渲染、不联网，也读不到别的文件：样式与脚本写进同一个 HTML，图片用 data: 地址内联，否则会缺失
      （命令会列出页面引用了、手机上拿不到的地址 outsideReferences，改成单个文件后再发一次）。
      经 iCloud 同步，所以 CuePad.app 需要在运行。Pi 里的 Agent 直接用 cuepad_show 工具即可，不必调这个命令。
      \(Schema.output("PiPreview {id, session, title, name, kind, bytes, outsideReferences}", "kind：web、image、pdf、markdown、text"))
      """
  ) { call in
    try call.args.expect("文件")
    guard let session = call.args.value("session") else { throw CLIError.usage("需要 --session <Pi 会话 id>") }
    let path = call.args.positionals[0]
    let url = URL(filePath: path, relativeTo: URL(filePath: call.directory, directoryHint: .isDirectory)).standardizedFileURL
    let added = try await call.store.addPreview(fileAt: url, title: call.args.value("title"), sessionID: session)
    let preview = added.preview
    var text = "已发到手机预览：\(preview.title)（\(preview.name)，\(preview.byteCount) 字节）\n"
    if !added.outsideReferences.isEmpty {
      text += "注意：页面引用了 \(added.outsideReferences.joined(separator: "、"))，手机上预览不联网、读不到别的文件，这些会缺失；改成单个文件后再发一次。\n"
    }
    let json: JSONObject = [
      "id": preview.id.uuidString.lowercased(), "session": session, "title": preview.title, "name": preview.name,
      "kind": preview.kind?.rawValue ?? "", "bytes": preview.byteCount, "outsideReferences": added.outsideReferences,
    ]
    return Reply(text: text, json: json)
  }
}
