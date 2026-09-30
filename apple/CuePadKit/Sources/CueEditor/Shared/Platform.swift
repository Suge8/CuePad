#if canImport(AppKit)
import AppKit
typealias CueView = NSView
typealias CueImage = NSImage
#elseif canImport(UIKit)
import UIKit
typealias CueView = UIView
typealias CueImage = UIImage
#endif
