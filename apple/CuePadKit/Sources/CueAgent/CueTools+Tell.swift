import CueStore
import CueText
import Foundation

extension CueTools {
  func tell(_ args: Args) async throws -> Result {
    let related = try await args.string("task").asyncMap(references.task)
    let message = try await store.addCueMessage(.cue, text: try args.required("text"), urgent: args.bool("urgent") ?? false, task: related?.id, answeredRequests: nil)
    return .ok("已告诉用户。（\(message.id.shortID)）\n\(CueToolReceipt(.reply, message.id).mark)")
  }

  func shots(_ raw: Any?) async throws -> [CueShot] {
    guard let raw else { return [] }
    guard let items = raw as? [[String: Any]] else { throw Failure("show 是数组：[{file, look}]") }
    var shots: [CueShot] = []
    for item in items {
      let key = (item["file"] as? String ?? "").trimmingCharacters(in: .whitespaces)
      let hits = key.isEmpty ? [] : try await store.previews(idPrefix: key)
      guard hits.count == 1 else {
        throw Failure(hits.isEmpty ? "发到手机的里没有 \(key)：照 task peek 里列的 id 写" : "前缀 \(key) 对上了 \(hits.count) 份：多写几位")
      }
      shots.append(CueShot(preview: hits[0].id, look: item["look"] as? String ?? ""))
    }
    return shots
  }
}
