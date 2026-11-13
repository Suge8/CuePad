import Foundation

extension AppServices {
    func startCaptureIngest() {
        let shared = DarwinNotifications.notifications(named: CaptureQueue.notification)  // 先订再扫：扫的途中分享进来的，通知不漏
        follow {
            await self.captures.drainCaptures()
            for await _ in shared {
                await self.captures.drainCaptures()
            }
        }
    }
}
