import SwiftUI

#if os(macOS)
import AppKit

struct InspirationSystemShare: NSViewRepresentable {
    @Binding var payload: InspirationPayload?

    func makeNSView(context: Context) -> NSView { NSView() }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func updateNSView(_ view: NSView, context: Context) {
        guard let payload, !context.coordinator.active else { return }
        let coordinator = context.coordinator
        coordinator.active = true
        Task { @MainActor in
            self.payload = nil
            coordinator.show(payload, from: view)
        }
    }

    final class Coordinator: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        var active = false
        private var payload: InspirationPayload?
        private var picker: NSSharingServicePicker?
        private var service: NSSharingService?
        private var lifetime: Coordinator?

        func show(_ payload: InspirationPayload, from view: NSView) {
            self.payload = payload
            lifetime = self
            let picker = NSSharingServicePicker(items: payload.items)
            self.picker = picker
            picker.delegate = self
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }

        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            picker = nil
            guard let service else { finish(); return }
            self.service = service
        }

        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? { self }
        func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { finish() }
        func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) { finish() }

        private func finish() {
            payload?.files?.remove()
            payload = nil
            service = nil
            picker = nil
            active = false
            lifetime = nil
        }
    }
}
#else
import UIKit

struct InspirationSystemShare: UIViewControllerRepresentable {
    @Binding var payload: InspirationPayload?

    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func updateUIViewController(_ controller: UIViewController, context: Context) {
        guard let payload, !context.coordinator.active else { return }
        let coordinator = context.coordinator
        coordinator.active = true
        Task { @MainActor in
            self.payload = nil
            coordinator.show(payload, from: controller)
        }
    }

    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        var active = false
        private var payload: InspirationPayload?
        private var lifetime: Coordinator?

        func show(_ payload: InspirationPayload, from host: UIViewController) {
            self.payload = payload
            lifetime = self
            let controller = UIActivityViewController(activityItems: payload.items, applicationActivities: DebugHooks.inspirationActivities())
            controller.completionWithItemsHandler = { [self] _, _, _, _ in finish() }
            controller.popoverPresentationController?.sourceView = host.view
            // 宿主铺满纸页；整页当锚会把 iPad 弹出层挤进顶栏，只取纸页顶边的一点。
            controller.popoverPresentationController?.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.minY, width: 0, height: 0)
            controller.presentationController?.delegate = self
            host.present(controller, animated: true)
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finish() }

        private func finish() {
            guard active else { return }
            payload?.files?.remove()
            payload = nil
            active = false
            lifetime = nil
        }
    }
}
#endif
