import Foundation

/// App Group defaults shared by the iOS app and the keyboard extension.
enum SharedDefaults {
    static let suiteName = "group.com.robbyfuu.copyd"
    static let lastSyncAtKey = "lastSyncAt"
    static var store: UserDefaults? { UserDefaults(suiteName: suiteName) }
}
