import SwiftUI

#if os(macOS)
import AppKit

struct InspirationSystemShare: NSViewRepresentable {
    let session: InspirationShareSession

    func makeNSView(context: Context) -> NSView { NSView() }
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.present(from: view) }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.closePicker() }

    final class Coordinator: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        private let session: InspirationShareSession
        private var presented = false
        private var presentation: Task<Void, Never>?
        private var picker: NSSharingServicePicker?
        private var service: NSSharingService?
        private var lifetime: Coordinator?

        init(session: InspirationShareSession) {
            self.session = session
            super.init()
            session.cancelPresentation = { [weak self] in self?.closePicker() }
        }

        func present(from view: NSView) {
            guard !presented else { return }
            presented = true
            lifetime = self
            presentation = Task { @MainActor in
                guard !Task.isCancelled else { return }
                let picker = NSSharingServicePicker(items: session.payload.items)
                self.picker = picker
                picker.delegate = self
                picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            }
        }

        func closePicker() {
            if let picker { picker.close() }
            else if service == nil {
                presentation?.cancel()
                finish()
            }
        }

        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            guard picker === sharingServicePicker else { return }
            picker = nil
            if let service { self.service = service }
            else { finish() }
        }

        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? { self }
        func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
            finish()
        }
        func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
            finish()
        }

        private func finish() {
            session.finish()
            service = nil
            picker = nil
            lifetime = nil
        }
    }
}
#else
import UIKit

struct InspirationSystemShare: UIViewControllerRepresentable {
    let session: InspirationShareSession

    func makeUIViewController(context: Context) -> Host {
        let host = Host()
        host.appear = { [coordinator = context.coordinator] in coordinator.present(from: $0) }
        return host
    }
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func updateUIViewController(_ controller: Host, context: Context) { }
    static func dismantleUIViewController(_ controller: Host, coordinator: Coordinator) { coordinator.cancelPendingPresentation() }

    /// 等宿主真正出现再交给 UIKit；准备浮层退场期间新插入的后台控制器还不能呈现分享。
    final class Host: UIViewController {
        var appear: ((Host) -> Void)?
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            appear?(self)
        }
    }

    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        private let session: InspirationShareSession
        private var presented = false
        private var lifetime: Coordinator?
        private var controller: UIActivityViewController?

        init(session: InspirationShareSession) {
            self.session = session
            super.init()
            session.cancelPresentation = { [weak self] in self?.cancelPendingPresentation() }
        }

        func cancelPendingPresentation() {
            if controller == nil {
                presented = true
                finish()
            }
        }

        func present(from host: UIViewController) {
            guard !presented else { return }
            presented = true
            lifetime = self
            let controller = UIActivityViewController(activityItems: session.payload.items, applicationActivities: DebugHooks.inspirationActivities())
            self.controller = controller
            controller.completionWithItemsHandler = { [self] _, _, _, _ in finish() }
            controller.popoverPresentationController?.sourceView = host.view
            // 宿主铺满纸页；整页当锚会把 iPad 弹出层挤进顶栏，只取纸页顶边的一点。
            controller.popoverPresentationController?.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.minY, width: 0, height: 0)
            controller.presentationController?.delegate = self
            host.present(controller, animated: true)
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finish() }

        private func finish() {
            session.finish()
            controller = nil
            lifetime = nil
        }
    }
}
#endif
