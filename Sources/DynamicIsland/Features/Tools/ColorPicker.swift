import AppKit
import SwiftUI

/// A color picked from the screen with the eyedropper.
struct PickedColor: Equatable {
    let color: Color
    /// "#1E90FF".
    let hex: String

    init?(_ nsColor: NSColor) {
        guard let srgb = nsColor.usingColorSpace(.sRGB) else { return nil }
        let components = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent]
            .map { Int((min(max($0, 0), 1) * 255).rounded()) }
        hex = String(format: "#%02X%02X%02X", components[0], components[1], components[2])
        color = Color(nsColor: srgb)
    }

    /// Parses "#1E90FF" or "1e90ff"; nil for anything else.
    init?(hex string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        self.init(NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        ))
    }
}

enum ColorPicker {
    /// The system eyedropper with its magnifier; calls back with nil if the user pressed Esc.
    @MainActor
    static func pick(completion: @escaping (PickedColor?) -> Void) {
        NSColorSampler().show { color in
            completion(color.flatMap(PickedColor.init))
        }
    }
}
