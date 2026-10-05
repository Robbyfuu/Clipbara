import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share to Copyd. Never opens the SwiftData store: Save drops the item in the App Group inbox,
/// and the app imports it the next time it opens.
final class ShareViewController: UIViewController {
    private let model = ShareModel()
    private var pending: (item: InboxItem, payload: Data?)?

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(
            model: model, onSave: { [weak self] in self?.save() }, onCancel: { [weak self] in self?.cancel() }))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await load() }
    }

    /// The first image, else the first URL, else the first plain text, across every attachment.
    private func load() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        func first(_ type: UTType) -> NSItemProvider? {
            providers.first { $0.hasItemConformingToTypeIdentifier(type.identifier) }
        }
        do {
            if let provider = first(.image) {
                // Saved whatever its size; sync skips clips over 20 MB.
                let data = try await loadData(provider)
                pending = (InboxItem(kind: .image, createdAt: Date()), data)
                model.content = .image(Thumbnail.png(from: data).flatMap(UIImage.init(data:)))
            } else if let provider = first(.url) {
                setText(try await loadObject(URL.self, from: provider).absoluteString)
            } else if let provider = first(.plainText) {
                setText(try await loadObject(String.self, from: provider))
            }
        } catch {}
        model.phase = pending == nil ? .failed : .ready
    }

    private func setText(_ text: String) {
        guard !text.isEmpty else { return }
        pending = (InboxItem(kind: .text, text: text, createdAt: Date()), nil)
        model.content = .text(text)
    }

    /// Synchronous on the main actor, so a second tap finds the phase already `.saved`.
    private func save() {
        guard model.phase == .ready, let pending, let group = SharedStore.groupContainer else { return model.phase = .failed }
        do {
            var item = pending.item
            item.createdAt = Date()
            try Inbox.write(item, payload: pending.payload, in: Inbox.directory(groupContainer: group))
        } catch {
            return model.phase = .failed
        }
        model.phase = .saved
        AccessibilityNotification.Announcement(String(localized: "Saved. It syncs next time you open Copyd.")).post()
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    private func loadData(_ provider: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(for: .image) { data, error in
                if let data { continuation.resume(returning: data) } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }

    private func loadObject<T: _ObjectiveCBridgeable & Sendable>(_ type: T.Type, from provider: NSItemProvider) async throws -> T
    where T._ObjectiveCType: NSItemProviderReading {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: type) { object, error in
                if let object { continuation.resume(returning: object) } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }
}
