import SwiftData
import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    private var container: ModelContainer?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureGlobe()
        model.onModeChange = { [weak self] in self?.reload() }
        model.onSelect = { [weak self] in self?.select($0) }
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
        reload()
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
        do {
            let container = try ModelContainer(
                for: ClipboardItem.self, Pinboard.self, PinboardEntry.self, ExcludedApp.self,
                configurations: ModelConfiguration(
                    url: SharedStore.url(groupContainer: group), allowsSave: false, cloudKitDatabase: .none))
            self.container = container
            let context = ModelContext(container)
            model.boards = try KeyboardFeed.boards(in: context)
            // The selected board may have been deleted on the Mac.
            if case .pinboard(let id) = model.mode, !model.boards.contains(where: { $0.id == id }) { model.mode = .recent }
            model.state = .loaded(try KeyboardFeed.items(in: context, mode: model.mode))
        } catch {
            model.state = .error
        }
    }

    /// Fetches the one full item, then inserts it or leaves it on the pasteboard. Returns a toast for the latter.
    private func select(_ clip: KeyboardClip) -> String? {
        let failure = String(localized: "Couldn't copy this clip.")
        guard let container else { return failure }
        let id = clip.id
        var descriptor = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let item = try? ModelContext(container).fetch(descriptor).first else { return failure }
        switch PasteAction.decide(contentType: item.contentType, text: item.textContent) {
        case .insert(let text):
            textDocumentProxy.insertText(text)
            return nil
        case .copyToPasteboard:
            if item.contentType == .image {
                guard let image = PasteboardImage.payload(from: item.rawData, maxPixels: 2048) else { return failure }
                UIPasteboard.general.setData(image.data, forPasteboardType: image.uti)
                return String(localized: "Copied. Touch and hold the field, then tap Paste.")
            }
            guard let text = item.textContent, !text.isEmpty else { return failure }
            UIPasteboard.general.string = text
            return String(localized: "Copied. It's too long to insert.")
        }
    }
}
