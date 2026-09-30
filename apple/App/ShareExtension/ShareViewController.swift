import CueStore
import SwiftUI
import UIKit

/// 分享面板里的入口：把系统给的内容交给 `ShareModel`，界面由 `ShareViews` 提供。
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let model: ShareModel
        do {
            model = ShareModel(providers: providers, location: try LibraryLocation.resolve())
        } catch {
            extensionContext?.cancelRequest(withError: error)
            return
        }
        let host = UIHostingController(rootView: ShareViews.root(
            model,
            dismiss: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) },
            cancel: { [weak self] in self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled)) }))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.load() }
    }
}
