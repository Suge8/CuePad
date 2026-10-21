#if canImport(AppKit)
import AppKit
typealias CueView = NSView
public typealias CueImage = NSImage
#elseif canImport(UIKit)
import UIKit
typealias CueView = UIView
public typealias CueImage = UIImage
#endif
