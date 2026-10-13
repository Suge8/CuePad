import CueStore
import Foundation
import Testing

/// "等你"由事实推出：关联的任务不再是没做完的（完成、归档、删了），那条就不再等你。
@Suite struct CueWaitingTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  @Test func aQuestionAboutATaskThatIsNoLongerOpenStopsWaiting() async throws {
    let project = try await store.createProject(name: "演示", color: "blue")
    let tasks = [
      try await store.createTask("完成的", in: nil), try await store.createTask("归档的", in: nil),
      try await store.createTask("删了的", in: nil), try await store.createTask("项目进回收站的", in: project.id),
      try await store.createTask("还在做的", in: nil),
    ]
    for task in tasks { try await store.addCueMessage(.cue, text: "收下「\(task.body)」？", choices: ["收下", "再改"], task: task.id) }
    try await store.addCueMessage(.cue, text: "要不要升级 Node？", choices: ["要", "不要"])
    #expect(try await store.cueMessagesWaitingForYou().count == 6)

    try await store.setStatus(tasks[0].id, .done)
    try await store.archive(tasks[1].id)
    try await store.trashCard(tasks[2].id)
    try await store.trashProject(project.id)
    #expect(try await store.cueMessagesWaitingForYou().map(\.text) == ["收下「还在做的」？", "要不要升级 Node？"])
  }
}
