import Foundation

/// Location of the SwiftData store inside the App Group container, shared by the iOS app and the keyboard.
enum SharedStore {
    /// `<container>/Library/Application Support/Copyd/Copyd.store`. Creates the `Copyd/` directory.
    static func url(groupContainer: URL) -> URL {
        let dir = groupContainer.appendingPathComponent("Library/Application Support/Copyd", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Copyd.store")
    }

    /// Pure check: never creates anything.
    static func storeExists(groupContainer: URL) -> Bool {
        let path = groupContainer.appendingPathComponent("Library/Application Support/Copyd/Copyd.store").path
        return FileManager.default.fileExists(atPath: path)
    }

    static var groupContainer: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedDefaults.suiteName)
    }
}
