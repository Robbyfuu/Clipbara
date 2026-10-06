import Foundation

/// An sRGB color, each channel in 0...1.
struct RGB: Equatable, Sendable {
    var r: Double
    var g: Double
    var b: Double

    /// "#RRGGBB".
    var hex: String {
        String(format: "#%02X%02X%02X", Self.byte(r), Self.byte(g), Self.byte(b))
    }

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// "#RRGGBB", with or without the "#"; nil for anything else.
    init?(hex: String) {
        guard let c = ColorFormat.rgb(hex: hex) else { return nil }
        self.init(r: Double(c.red) / 255, g: Double(c.green) / 255, b: Double(c.blue) / 255)
    }

    private static func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
}

/// The color a card header takes from its source app's icon.
enum IconColor {
    private static let grid = 32

    /// `rgba` is `width`×`height` premultiplied RGBA bytes, rows top to bottom (a `premultipliedLast` CGContext).
    /// 1. Samples a 32×32 grid. 2. Skips pixels with alpha < 128. 3. Skips near-white and near-black (luma > 0.92 or
    /// < 0.08) when at least 20 % of the opaque pixels remain. 4. Quantizes to 4 bits per channel and averages the
    /// most frequent bucket. A fully transparent icon gives neutral gray.
    static func dominant(rgba: [UInt8], width: Int, height: Int) -> RGB {
        var opaque: [(r: Int, g: Int, b: Int)] = []
        if width > 0, height > 0, rgba.count >= width * height * 4 {
            for gy in 0..<grid {
                for gx in 0..<grid {
                    let i = ((gy * height / grid) * width + gx * width / grid) * 4
                    let a = Int(rgba[i + 3])
                    guard a >= 128 else { continue }
                    func straight(_ c: UInt8) -> Int { min(255, Int(c) * 255 / a) }
                    opaque.append((straight(rgba[i]), straight(rgba[i + 1]), straight(rgba[i + 2])))
                }
            }
        }
        guard !opaque.isEmpty else { return RGB(r: 0.5, g: 0.5, b: 0.5) }

        let colored = opaque.filter {
            let luma = (0.2126 * Double($0.r) + 0.7152 * Double($0.g) + 0.0722 * Double($0.b)) / 255
            return luma <= 0.92 && luma >= 0.08
        }
        let pixels = colored.count * 5 >= opaque.count ? colored : opaque

        var buckets = [[(r: Int, g: Int, b: Int)]](repeating: [], count: 4096)
        for p in pixels { buckets[(p.r >> 4) << 8 | (p.g >> 4) << 4 | p.b >> 4].append(p) }
        // The first bucket of the largest size: ties resolve the same way every time.
        let top = buckets.max { $0.count < $1.count } ?? pixels
        let n = Double(top.count) * 255
        return RGB(r: Double(top.reduce(0) { $0 + $1.r }) / n,
                   g: Double(top.reduce(0) { $0 + $1.g }) / n,
                   b: Double(top.reduce(0) { $0 + $1.b }) / n)
    }
}
