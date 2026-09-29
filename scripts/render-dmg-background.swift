// Draws the background of the disk image window: the aurora from the README images, an arrow
// from where Island sits to where Applications does, and how to get past Gatekeeper the first
// time. make-dmg.sh runs it:  swift scripts/render-dmg-background.swift <output.tiff>
//
// The layout must match the icon positions in make-dmg.sh.

import AppKit
import SwiftUI

let size = CGSize(width: 660, height: 400)
/// Centers of the two icons, from the top left; make-dmg.sh places them here.
let appCenter = CGPoint(x: 170, y: 200)
let applicationsCenter = CGPoint(x: 490, y: 200)

struct Background: View {
    var body: some View {
        ZStack(alignment: .top) {
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.45, 0.55], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ], colors: [
                Color(red: 0.10, green: 0.08, blue: 0.25), Color(red: 0.16, green: 0.10, blue: 0.36), Color(red: 0.06, green: 0.16, blue: 0.30),
                Color(red: 0.30, green: 0.12, blue: 0.42), Color(red: 0.07, green: 0.30, blue: 0.42), Color(red: 0.05, green: 0.40, blue: 0.40),
                Color(red: 0.55, green: 0.20, blue: 0.45), Color(red: 0.10, green: 0.22, blue: 0.45), Color(red: 0.05, green: 0.12, blue: 0.22),
            ])

            // A soft glow under each icon, so they sit on something.
            ForEach([appCenter, applicationsCenter], id: \.x) { center in
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.13), .clear], center: .center, startRadius: 0, endRadius: 95))
                    .frame(width: 190, height: 190)
                    .position(center)
            }

            Arrow()
                .stroke(.white.opacity(0.5), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 140, height: 26)
                .position(x: (appCenter.x + applicationsCenter.x) / 2, y: appCenter.y - 8)

            VStack(spacing: 6) {
                Text("Drag Island to Applications")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Перетащи Island в «Программы»")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.top, 38)

            VStack(spacing: 4) {
                Text("First launch: System Settings → Privacy & Security → Open Anyway")
                Text("Первый запуск: Системные настройки → Конфиденциальность и безопасность → Всё равно открыть")
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 26)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// A shallow arc with a head.
struct Arrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = CGPoint(x: rect.minX, y: rect.maxY)
        let end = CGPoint(x: rect.maxX, y: rect.maxY)
        let control = CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.6)
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        // The head follows the curve where it ends: along the line from the control point.
        let angle = atan2(end.y - control.y, end.x - control.x)
        for side in [-1.0, 1.0] {
            let wing = angle + .pi - side * .pi / 5
            path.move(to: CGPoint(x: end.x + 14 * cos(wing), y: end.y + 14 * sin(wing)))
            path.addLine(to: end)
        }
        return path
    }
}

@MainActor func render(scale: CGFloat) -> NSBitmapImageRep {
    let renderer = ImageRenderer(content: Background().environment(\.colorScheme, .dark))
    renderer.scale = scale
    let image = renderer.cgImage!
    let bitmap = NSBitmapImageRep(cgImage: image)
    // Points, not pixels: the 2x version is the same size on screen, just sharper.
    bitmap.size = size
    return bitmap
}

guard CommandLine.arguments.count == 2 else {
    print("usage: swift scripts/render-dmg-background.swift <output.tiff>")
    exit(1)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
MainActor.assumeIsolated {
    // One TIFF with both resolutions: Finder picks the one for the screen.
    let image = NSImage(size: size)
    image.addRepresentation(render(scale: 1))
    image.addRepresentation(render(scale: 2))
    let data = image.tiffRepresentation(using: .lzw, factor: 0)!
    try! data.write(to: output)
}
print("Wrote \(output.path)")
