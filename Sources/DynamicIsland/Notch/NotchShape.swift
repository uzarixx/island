import SwiftUI

/// Rectangle with concave top corners (flowing into the screen edge) and rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let bottom = min(bottomRadius, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
            control: CGPoint(x: rect.minX + topRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + topRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topRadius - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topRadius, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
