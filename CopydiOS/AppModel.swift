import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers
import OSLog

/// Owns the shared store and the sync engine for the iOS app.
@MainActor @Observable
final class AppModel {
    private static let log = Logger(subsystem: "com.robbyfuu.copyd", category: "AppModel")

    let container: ModelContainer
    let sync: CloudSyncEngine
    /// True when the App Group container was unavailable and the store lives in memory only.
    let isInMemory: Bool
    var toastVisible = false
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init() {
        UserDefaults.standard.register(defaults: [CloudSyncEngine.enabledDefaultsKey: true])
        let schema = Schema([ClipboardItem.self, Pinboard.self, PinboardEntry.self, ExcludedApp.self])
        var inMemory = false
        let configuration: ModelConfiguration
        if let group = SharedStore.groupContainer {
            configuration = ModelConfiguration(schema: schema, url: SharedStore.url(groupContainer: group), cloudKitDatabase: .none)
        } else {
            Self.log.error("App Group container unavailable, using an in-memory store")
            inMemory = true
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        }
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create the store: \(error)")
        }
        isInMemory = inMemory
        sync = CloudSyncEngine(container: container) {}
        if UserDefaults.standard.bool(forKey: CloudSyncEngine.enabledDefaultsKey) { sync.start() }
    }

    /// Copies the clip to the pasteboard and flashes the "Copied" toast.
    func copy(_ item: ClipboardItem) {
        switch item.contentType {
        case .image:
            if let png = UIImage(data: item.rawData)?.pngData() {
                UIPasteboard.general.setData(png, forPasteboardType: UTType.png.identifier)
            }
        default:
            UIPasteboard.general.string = item.textContent
        }
        toastTask?.cancel()
        toastVisible = true
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            if !Task.isCancelled { toastVisible = false }
        }
    }
}
