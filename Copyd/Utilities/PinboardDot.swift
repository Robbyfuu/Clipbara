import Foundation

enum PinboardDot {
    static let paletteCount = 6

    /// Stable across launches (never hashValue, which is randomized per process).
    static func index(for id: UUID) -> Int {
        withUnsafeBytes(of: id.uuid) { bytes in
            bytes.reduce(0) { $0 + Int($1) }
        } % paletteCount
    }
}
