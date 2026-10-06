import SwiftData
import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    private var container: ModelContainer?
    /// A copy this keyboard captured. It leads Recent until the store has it; a tap uses its content directly.
    private var clipboard: (card: KeyboardClip, clip: CapturedClip, changeCount: Int)?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureGlobe()
        model.onModeChange = { [weak self] in self?.reload() }
        model.onSelect = { [weak self] in self?.select($0) }
        model.onInsertAs = { [weak self] in self?.insert($0, as: $1) }
        model.onMenu = { [weak self] clip in
            guard let self else { return [] }
            return KeyboardFeed.menu(for: clip, text: self.text(of: clip))
        }
        model.onText = { [weak self] in self?.textDocumentProxy.insertText($0) }
        model.onDelete = { [weak self] in self?.textDocumentProxy.deleteBackward() }
        model.onOpenApp = { [weak self] in
            guard let self, let url = URL(string: "copyd://keyboard-setup") else { return }
            OpenContainingApp.open(url, from: self)
        }

        let host = UIHostingController(rootView: KeyboardView(model: model))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        // 999, not required: a required height conflicts with the system's own constraints on rotation.
        let height = host.view.heightAnchor.constraint(equalToConstant: 280)
        height.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height,
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.showsGlobe = needsInputModeSwitchKey
        // Settings' permissions card reads this as proof of Full Access: never written without it, at most once a day.
        let defaults = SharedDefaults.store
        if hasFullAccess, PermissionStatus.shouldRecordFullAccess(
            seenAt: defaults?.object(forKey: SharedDefaults.keyboardFullAccessSeenAtKey) as? Date, now: Date()) {
            defaults?.set(Date(), forKey: SharedDefaults.keyboardFullAccessSeenAtKey)
        }
        captureClipboard()
        reload()
    }

    /// Queues a copy made since Copyd last looked. A keyboard cannot write the store, so the copy goes to the inbox,
    /// which the app drains the next time it opens. Text and URLs only: an image is left for the app, unread.
    private func captureClipboard() {
        guard hasFullAccess, let group = SharedStore.groupContainer, SharedStore.storeExists(groupContainer: group) else { return }
        guard let clip = PasteboardCapture.newClip(readsImages: false) else {
            // A new copy (an image, or a private one) replaced the card's; an unchanged count keeps it.
            if clipboard?.changeCount != UIPasteboard.general.changeCount { clipboard = nil }
            return
        }
        let image = clip.contentType == .image
        let item = InboxItem(kind: image ? .image : .text, text: clip.textContent, createdAt: Date(),
                             source: UIDevice.current.model, auto: true)
        do {
            try Inbox.write(item, payload: image ? clip.rawData : nil, in: Inbox.directory(groupContainer: group))
        } catch {
            PasteboardCapture.leaveForApp()
        }
        clipboard = (KeyboardFeed.clipboardCard(clip, now: Date()), clip, UIPasteboard.general.changeCount)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.endDelete()
    }

    private func configureGlobe() {
        model.globeButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
    }

    /// Order matters: Full Access, then the store file, then open and fetch, then empty.
    private func reload() {
        model.lastSync = SharedDefaults.store?.object(forKey: SharedDefaults.lastSyncAtKey) as? Date
        guard hasFullAccess else { return model.state = .noFullAccess }
        guard let group = SharedStore.groupContainer, SharedStore.storeExists(groupContainer: group) else {
            return model.state = .noStore
        }
        // The app's own schema: a read-only open of a store holding an entity it lacks can fail. Until the updated app
        // migrates the store, opening it with the new schema fails too: the app fixes both.
        guard let container = try? ModelContainer(
            for: Schema(StoreSchema.models),
            configurations: ModelConfiguration(
                url: SharedStore.url(groupContainer: group), allowsSave: false, cloudKitDatabase: .none))
        else { return model.state = .needsApp }
        do {
            self.container = container
            let context = ModelContext(container)
            model.boards = try KeyboardFeed.boards(in: context)
            model.smartBoards = SmartKinds.isEnabled ? try KeyboardFeed.smartBoards(in: context) : []
            // The selected board may have been deleted on the Mac, or an automatic one emptied or turned off.
            if case .pinboard(let id) = model.mode, !model.boards.contains(where: { $0.id == id }) { model.mode = .recent }
            if case .smart(let board) = model.mode, !model.smartBoards.contains(board) { model.mode = .recent }
            // Once the app has stored the copy (or it was already there), the feed shows it instead.
            if let hash = clipboard?.clip.contentHash, (try? ClipCapture.existsInHistory(hash: hash, in: context)) == true {
                clipboard = nil
            }
            let items = try KeyboardFeed.items(in: context, mode: model.mode)
            // Each app's icon, decoded once at 42 px (14 pt at 3x) and kept: never a 128 px icon per card.
            let missing = Set(items.compactMap(\.sourceAppBundleId)).subtracting(model.icons.keys)
            if let icons = try? AppIdentity.icons(for: missing, maxPixels: 42, in: context), !icons.isEmpty {
                model.icons.merge(icons.mapValues { UIImage(cgImage: $0) }) { $1 }
            }
            model.state = .loaded(model.mode == .recent ? (clipboard.map { [$0.card] } ?? []) + items : items)
        } catch {
            model.state = .error
        }
    }

    /// Fetches the one full item (or takes the captured copy), then inserts it or leaves it on the pasteboard.
    /// Returns a toast for the latter.
    private func select(_ clip: KeyboardClip) -> String? {
        if clip.isClipboard, let captured = clipboard?.clip {
            return paste(captured.contentType, text: captured.textContent, data: captured.rawData)
        }
        guard let item = item(for: clip) else { return Self.failure }
        return paste(item.contentType, text: item.textContent, data: item.rawData)
    }

    /// "Insert as…": the clip's whole text, transformed, inserted as plain text, or copied when too long to insert.
    /// The menu came from the text's first 4 KB: when the whole text doesn't support the pick (JSON that turns invalid
    /// later), nothing happens.
    private func insert(_ clip: KeyboardClip, as transform: TextTransform) -> String? {
        guard let text = text(of: clip) else { return Self.failure }
        guard let result = transform.apply(to: text) else { return nil }
        return paste(.plainText, text: result, data: Data())
    }

    /// The clip's whole text. A masked clipboard card has its real text.
    private func text(of clip: KeyboardClip) -> String? {
        clip.isClipboard ? clipboard?.clip.textContent : item(for: clip)?.textContent
    }

    private func item(for clip: KeyboardClip) -> ClipboardItem? {
        guard let container else { return nil }
        let id = clip.id
        var descriptor = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? ModelContext(container).fetch(descriptor).first
    }

    private static var failure: String { String(localized: "Couldn't copy this clip.") }

    /// `data` is read only for an image, so a text clip's raw bytes never load.
    private func paste(_ type: ContentType, text: String?, data: @autoclosure () -> Data) -> String? {
        switch PasteAction.decide(contentType: type, text: text) {
        case .insert(let text):
            textDocumentProxy.insertText(text)
            return nil
        case .copyToPasteboard:
            if type == .image {
                guard let image = PasteboardImage.payload(from: data(), maxPixels: 2048) else { return Self.failure }
                UIPasteboard.general.setData(image.data, forPasteboardType: image.uti)
                PasteboardCapture.markHandled()  // the keyboard's own copy is never captured back
                return String(localized: "Copied. Touch and hold the field, then tap Paste.")
            }
            guard let text, !text.isEmpty else { return Self.failure }
            UIPasteboard.general.string = text
            PasteboardCapture.markHandled()
            return String(localized: "Copied. It's too long to insert.")
        }
    }
}
