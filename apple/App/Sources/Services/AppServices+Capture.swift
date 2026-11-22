import Foundation

extension AppServices {
    func startCaptureIngest() {
        let shared = DarwinNotifications.notifications(named: CaptureQueue.notification)
        follow {
            await self.captures.drainCaptures()
            for await _ in shared {
                await self.captures.drainCaptures()
            }
        }
    }
}
