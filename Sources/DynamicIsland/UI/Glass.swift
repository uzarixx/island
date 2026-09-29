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

/// What follows the cursor while something is dragged out of the notch. Anything with glass
/// needs one: SwiftUI can't snapshot Liquid Glass and draws a yellow "unsupported" placeholder.
struct DragPreview: View {
    var image: NSImage?
    var symbol = "doc"
    var title: String?

    var body: some View {
        if let image {
            // Like Finder: the picture itself, no card around it.
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 120, maxHeight: 90)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                if let title {
                    Text(title).lineLimit(1).frame(maxWidth: 160, alignment: .leading)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(Color(white: 0.18)))
            .environment(\.colorScheme, .dark)
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
