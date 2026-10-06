import SwiftUI

enum ColorFormat {
    /// The red, green and blue bytes of "#RRGGBB". The "#" and surrounding whitespace are optional.
    static func rgb(hex: String) -> (red: Int, green: Int, blue: Int)? {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        guard hexSanitized.count == 6,
              let hexNumber = UInt64(hexSanitized, radix: 16) else {
            return nil
        }
        return (Int((hexNumber & 0xFF0000) >> 16), Int((hexNumber & 0x00FF00) >> 8), Int(hexNumber & 0x0000FF))
    }

    /// "RGB 52, 120, 246" for "#3478F6"; nil when `hex` is not a six-digit color.
    static func rgbString(hex: String) -> String? {
        rgb(hex: hex).map { "RGB \($0.red), \($0.green), \($0.blue)" }
    }
}

extension Color {
    init?(hex: String) {
        guard let rgb = ColorFormat.rgb(hex: hex) else { return nil }
        self.init(red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
    }
}
