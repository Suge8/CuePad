#if DEBUG
import SwiftUI

extension DebugSceneEntry {
    static let stateIcons = DebugSceneEntry("stateicons", overlay: { _ in
        #if os(macOS)
        return AnyView(StateGlyphSheet().withPalette())
        #else
        return AnyView(StateGlyphSheet())
        #endif
    })

    static let rail = DebugSceneEntry("rail", overlay: { workspace in
        AnyView(DebugSessionRail(workspace: workspace).modifier(PaletteProvider()))
    })

    #if os(iOS)
    static let sheets = DebugSceneEntry("style", "icons", "widgets", "activity", "share", overlay: { workspace in
        switch DebugScene.scene {
        case "style": AnyView(StyleBoard())
        case "icons": AnyView(IconSheet())
        case "widgets": AnyView(DebugWidgetStage())
        case "activity": AnyView(DebugActivityStage(workspace: workspace))
        default: AnyView(DebugShareStage(location: workspace.services.location))
        }
    })
    #endif
}
#endif
