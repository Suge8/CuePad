#if DEBUG
import SwiftUI

extension DebugSceneEntry {
    /// stateicons：状态图形总览（`StateGlyphSheet`，一列往下滚），盖在最上层。
    static let stateIcons = DebugSceneEntry("stateicons", overlay: { _ in
        #if os(macOS)
        return AnyView(StateGlyphSheet().withPalette())
        #else
        return AnyView(StateGlyphSheet())
        #endif
    })

    /// rail：会话条样板（`DebugSessionRail`，`-CuePadRailEmpty YES` 验空列占位）。
    static let rail = DebugSceneEntry("rail", overlay: { workspace in
        AnyView(DebugSessionRail(workspace: workspace).modifier(PaletteProvider()))
    })

    #if os(iOS)
    /// style：视觉样板（`StyleBoard`）；icons：图标总览（`IconSheet`，iPad 竖屏一屏）；widgets：小组件的小号与中号；activity：实时活动的各态；share：分享扩展的表单。都盖在最上层。
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
