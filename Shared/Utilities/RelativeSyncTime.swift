import Foundation

enum RelativeSyncTime {
    static func text(from date: Date?, now: Date) -> String {
        guard let date else { return "Never synced" }
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return "Updated now"  // includes future dates (clock skew)
        case ..<3600: return "Updated \(Int(seconds / 60)) min ago"
        case ..<86_400: return "Updated \(Int(seconds / 3600)) h ago"
        default: return "Updated \(Int(seconds / 86_400)) d ago"
        }
    }
}
