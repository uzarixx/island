// Renders Resources/Logo.svg into Resources/AppIcon.png (1024×1024), which build.sh turns into
// the app icon. Run after editing the logo:  swift scripts/render-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = root.appending(path: "Resources/Logo.svg")
let output = root.appending(path: "Resources/AppIcon.png")
let size = 1024

guard let image = NSImage(contentsOf: source) else {
    print("Couldn't read \(source.path)")
    exit(1)
}
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
print("Wrote \(output.path)")
