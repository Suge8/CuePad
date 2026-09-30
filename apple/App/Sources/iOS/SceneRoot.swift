#if os(iOS)
import SwiftUI

/// 每个窗口的壳：注入服务与窗口状态、恢复选中项目、处理深链接、进入后台前落盘。
struct SceneRoot: View {
    let services: AppServices
    @State private var scene = SceneContext()
    @SceneStorage("currentProject") private var storedProject = ""
    @Environment(\.scenePhase) private var phase

    var body: some View {
        IOSRootViews.root()
            .environment(services)
            .environment(scene)
            .onAppear { scene.currentProject = UUID(uuidString: storedProject) }
            .onChange(of: scene.currentProject) { _, project in storedProject = project?.uuidString ?? "" }
            .onOpenURL { services.handle(url: $0) }
            .onChange(of: phase) { _, phase in
                switch phase {
                case .active: Task {
                    await services.drainCaptures()
                    await services.handleActivation()
                }
                case .background: Task { await BackgroundWork.run { await services.prepareForBackground() } }
                default: break
                }
            }
    }
}

/// 让进入后台后的收尾工作有时间跑完（系统随后才挂起进程）。
@MainActor
enum BackgroundWork {
    static func run(_ work: @MainActor () async -> Void) async {
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "CuePad.flush") {
            UIApplication.shared.endBackgroundTask(task)
        }
        await work()
        UIApplication.shared.endBackgroundTask(task)
    }
}
#endif
