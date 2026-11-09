#if os(iOS)
import UIKit

enum Clipboard {
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }
}
#endif
