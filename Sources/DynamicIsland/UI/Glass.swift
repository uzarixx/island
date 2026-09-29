import SwiftUI

/// Liquid Glass for controls inside the notch (the notch itself stays black so it blends into
/// the camera cutout). Before macOS 26 it falls back to the flat translucent fills used before.
extension View {
    @ViewBuilder
    func notchGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        fallback: Color = .white.opacity(0.08)
    ) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(shape.fill(tint ?? fallback))
        }
    }
}

/// Groups glass shapes so nearby ones blend and morph into each other (macOS 26+).
struct NotchGlassContainer<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
    }
}
