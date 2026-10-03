import Foundation

/// Compact age for clip cards: "now", "5 min", "3 h", "2 d".
enum ClipAge {
    static func text(from date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return "now"  // includes future dates (clock skew)
        case ..<3600: return "\(Int(seconds / 60)) min"
        case ..<86_400: return "\(Int(seconds / 3600)) h"
        default: return "\(Int(seconds / 86_400)) d"
        }
    }
}
