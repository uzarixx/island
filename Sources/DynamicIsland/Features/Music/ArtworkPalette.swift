import AppKit
import SwiftUI

/// Two accent colors from an album cover, for the equalizer gradient (like Spotify on iPhone).
enum ArtworkPalette {
    private static let side = 32
    private static let hueBuckets = 12

    /// Nil only if the image can't be read. Covers with no real color (white, black and white
    /// photos, gray text on black) get a light neutral gradient rather than the default green.
    static func colors(from image: NSImage) -> [Color]? {
        guard let pixels = pixels(of: image) else { return nil }

        // Colorful pixels grouped by hue. The score favors vivid, bright colors over large dull areas.
        var buckets = [(score: CGFloat, red: CGFloat, green: CGFloat, blue: CGFloat, count: CGFloat)](
            repeating: (0, 0, 0, 0, 0), count: hueBuckets
        )
        // Every pixel that isn't near black, for the tint of a colorless cover.
        var average = (red: CGFloat(0), green: CGFloat(0), blue: CGFloat(0), count: CGFloat(0))
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = CGFloat(pixels[index]) / 255
            let green = CGFloat(pixels[index + 1]) / 255
            let blue = CGFloat(pixels[index + 2]) / 255
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
            NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
                .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
            if brightness > 0.2 {
                average = (average.red + red, average.green + green, average.blue + blue, average.count + 1)
            }
            guard saturation > 0.2, brightness > 0.2 else { continue }

            let bucket = min(Int(hue * CGFloat(hueBuckets)), hueBuckets - 1)
            buckets[bucket].score += saturation * brightness
            buckets[bucket].red += red
            buckets[bucket].green += green
            buckets[bucket].blue += blue
            buckets[bucket].count += 1
        }

        let ranked = buckets.indices.filter { buckets[$0].count > 0 }.sorted { buckets[$0].score > buckets[$1].score }
        // A few stray pixels don't make a cover colorful.
        guard let first = ranked.first, buckets[first].count >= CGFloat(side * side) / 50 else {
            let tint = average.count > 0
                ? NSColor(srgbRed: average.red / average.count, green: average.green / average.count, blue: average.blue / average.count, alpha: 1)
                // Not `.white`: that's a gray color space, which getHue throws on.
                : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            return neutral(tint)
        }

        func color(_ bucket: Int) -> NSColor {
            let b = buckets[bucket]
            return NSColor(srgbRed: b.red / b.count, green: b.green / b.count, blue: b.blue / b.count, alpha: 1)
        }
        // The second color should be a noticeably different hue; otherwise a lighter shade of the first.
        let second = ranked.dropFirst().first { bucket in
            let distance = abs(bucket - first)
            return min(distance, hueBuckets - distance) >= 2 && buckets[bucket].score >= buckets[first].score * 0.15
        }
        let primary = color(first)
        let secondary = second.map(color) ?? primary.blended(withFraction: 0.45, of: .white) ?? primary
        return [readable(primary), readable(secondary)]
    }

    /// White fading to silver, keeping a hint of the cover's tint (a sepia photo stays warm).
    private static func neutral(_ tint: NSColor) -> [Color] {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        tint.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        let hint = min(saturation, 0.12)
        return [
            Color(hue: hue, saturation: hint * 0.5, brightness: 0.97),
            Color(hue: hue, saturation: hint, brightness: 0.62),
        ]
    }

    /// Bright and saturated enough to stand out on the black notch.
    private static func readable(_ color: NSColor) -> Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return Color(hue: hue, saturation: min(max(saturation, 0.4), 0.85), brightness: max(brightness, 0.8))
    }

    /// The image scaled down to `side`×`side`, as RGBA bytes.
    private static func pixels(of image: NSImage) -> [UInt8]? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? pixels : nil
    }
}
