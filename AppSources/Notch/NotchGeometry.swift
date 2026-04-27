import AppKit

/// Real-screen geometry for the floating notch overlay.
///
/// Approach (reimplemented from understanding MioIsland's geometry):
/// - The hardware notch's true width comes from
///   `screen.auxiliaryTopLeftArea` and `auxiliaryTopRightArea`, the menu-bar
///   strips on either side of the camera cutout. The notch width is
///   `frame.width - leftStrip - rightStrip`.
/// - The panel is **centered on the notch** (which sits at `screen.midX`),
///   with "wings" extending outward by `expansionWidth/2` on each side.
/// - Wings give us room for content (status / buddy / project name) while
///   the actual notch hardware sits in the middle, visually merging with
///   our black bar background.
struct NotchGeometry {
    /// Default extra width (split equally between left and right wings).
    static let defaultExpansionWidth: CGFloat = 240
    /// Drawer height when expanded — fits the permission panel OR a small
    /// session list. Rows are ~52pt; this height comfortably shows ~3 rows
    /// plus the "N sessions" header and padding. Beyond that the list scrolls.
    static let expandedDrawerHeight: CGFloat = 260
    /// Top-corner inward curve at the wing tips. A pronounced radius here is
    /// what makes the wings visually "grow out of" the notch instead of
    /// looking like rectangular extrusions.
    static let topCornerRadius: CGFloat = 18
    /// Bottom-corner outward rounding where the wing's lower edge curves into
    /// the wallpaper. Larger value = softer transition.
    static let bottomCornerRadius: CGFloat = 32

    let screen: NSScreen
    let isNotched: Bool
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    init(screen: NSScreen) {
        self.screen = screen
        let safeTop = screen.safeAreaInsets.top
        self.isNotched = safeTop > 0
        self.notchHeight = isNotched ? safeTop : 24  // fallback to menu bar height
        if isNotched {
            let leftStrip = screen.auxiliaryTopLeftArea?.width ?? 0
            let rightStrip = screen.auxiliaryTopRightArea?.width ?? 0
            // Real notch width = whatever's NOT covered by the two strips.
            // On 14"/16" MBP this comes out to ~200pt; we don't hardcode.
            let computed = screen.frame.width - leftStrip - rightStrip
            self.notchWidth = max(computed, 140)  // floor for stability
        } else {
            // Without a hardware notch we still want a small "virtual" width
            // so the wing geometry math behaves the same.
            self.notchWidth = 140
        }
    }

    /// Frame for the collapsed (always-visible) bar in screen coordinates.
    /// Centered on the notch; height equals the notch height.
    func collapsedFrame(expansionWidth: CGFloat = defaultExpansionWidth) -> NSRect {
        let totalWidth = notchWidth + expansionWidth
        let originX = screen.frame.midX - totalWidth / 2
        let originY = screen.frame.maxY - notchHeight
        return NSRect(x: originX, y: originY, width: totalWidth, height: notchHeight)
    }

    /// Frame for the expanded panel — wider than collapsed so session-row
    /// content has breathing room, and grows downward to host the drawer.
    func expandedFrame(expansionWidth: CGFloat = defaultExpansionWidth) -> NSRect {
        // Two visual costs eat width: the inward top-corner curve (tr=18pt)
        // pulls the visible shape in by tr on each side, and the drawer's
        // horizontal padding (28pt) pulls content in further. Total margin
        // each side ≈ 46pt × 2 = 92pt of "lost" width before any content
        // shows. Make the panel generous so rows don't feel cramped.
        let widerExpansion = max(expansionWidth, 480)
        let totalWidth = notchWidth + widerExpansion
        let originX = screen.frame.midX - totalWidth / 2
        let totalHeight = notchHeight + Self.expandedDrawerHeight
        let originY = screen.frame.maxY - totalHeight
        return NSRect(x: originX, y: originY, width: totalWidth, height: totalHeight)
    }

    static func bestScreen() -> NSScreen {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main ?? NSScreen.screens.first!
    }
}
