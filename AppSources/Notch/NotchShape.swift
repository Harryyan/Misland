import SwiftUI

/// Custom shape that mimics the visual signature of an extended notch:
///
/// - Top edge: flush with the screen edge across the middle (where the
///   physical notch is) and curving INWARD at the wing tips. The inward
///   top-corners make the wings look like they're growing organically out
///   of the notch hardware rather than being separate appendages.
/// - Bottom edge: standard outward-rounded corners with a larger radius
///   so the bar tapers gently into the wallpaper.
///
/// (Algorithm reimplemented from understanding how MioIsland constructs
/// its notch shape with quadratic Bezier curves; written from scratch with
/// our own variable naming and structure.)
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    init(topRadius: CGFloat = NotchGeometry.topCornerRadius,
         bottomRadius: CGFloat = NotchGeometry.bottomCornerRadius) {
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let tr = topRadius
        let br = bottomRadius

        // Start at the top-left corner of the bounding rect.
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Top-left "inward" curve: from the screen edge in and down to
        // (minX+tr, minY+tr). The control point at (minX+tr, minY) creates
        // an inward bulge — the corner appears to indent into the bar.
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
            control: CGPoint(x: rect.minX + tr, y: rect.minY)
        )

        // Down the left side to where the bottom-left rounding begins.
        p.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - br))

        // Bottom-left "outward" rounded corner.
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + tr + br, y: rect.maxY),
            control: CGPoint(x: rect.minX + tr, y: rect.maxY)
        )

        // Across the bottom to the start of the bottom-right rounding.
        p.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY))

        // Bottom-right "outward" rounded corner.
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br),
            control: CGPoint(x: rect.maxX - tr, y: rect.maxY)
        )

        // Up the right side to where the top-right inward curve begins.
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))

        // Top-right "inward" curve back up to the top edge.
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - tr, y: rect.minY)
        )

        // Close along the top edge.
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        return p
    }
}
