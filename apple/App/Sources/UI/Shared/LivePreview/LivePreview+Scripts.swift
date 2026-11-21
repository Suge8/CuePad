import Foundation

/// 载完后在页面里读的两样（`LivePreview.sampleGround`、`adoptViewport`）。
extension LivePreview {
    static let groundScript = """
        const solid = element => {
            const color = element && getComputedStyle(element).backgroundColor;
            return color && !/^(transparent|rgba\\(.*,\\s*0\\))$/.test(color) ? color : null;
        };
        const canvas = () => {
            const probe = document.createElement("div");
            probe.style.background = "Canvas";
            document.documentElement.append(probe);
            const color = getComputedStyle(probe).backgroundColor;
            probe.remove();
            return color;
        };
        return solid(document.documentElement) ?? solid(document.body) ?? canvas();
        """

    static let viewportScript = #"return document.querySelector('meta[name="cuepad-viewport"]')?.content"#
}
