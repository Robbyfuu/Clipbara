import SwiftData

/// The models every target opens the store with: the iPhone app, its keyboard and widget, and (plus `PasteEvent`)
/// the Mac. One list, so a read-only extension never opens a store holding an entity its schema lacks.
enum StoreSchema {
    static var models: [any PersistentModel.Type] {
        [ClipboardItem.self, Pinboard.self, PinboardEntry.self, ExcludedApp.self, AppIdentity.self]
    }
}
