import Foundation
import SwiftData

/// One item the Share extension handed over: `<id>.json` in the inbox, plus `<id>.payload` for an image.
struct InboxItem: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case text, image }

    var id = UUID()
    var kind: Kind
    var text: String?
    /// File name of the image bytes, next to the JSON. `write` sets it.
    var payloadFile: String?
    var createdAt: Date
    /// The sharing app's name. The extension cannot tell it reliably, so it is nil and the clip reads "Share".
    var source: String?
}

/// The Share extension never opens the SwiftData store: it drops files here, and the app imports them.
/// This keeps the app the store's only writer.
enum Inbox {
    /// `<group>/Library/Application Support/Copyd/Inbox`. Creates it.
    static func directory(groupContainer: URL) -> URL {
        let dir = groupContainer.appendingPathComponent("Library/Application Support/Copyd/Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The payload goes first and the JSON last, through a temp file renamed to `<id>.json`. The drain only reads
    /// `*.json`, so it never sees a half-written item, and every JSON it sees has its payload complete.
    static func write(_ item: InboxItem, payload: Data?, in directory: URL) throws {
        var item = item
        let payloadURL = directory.appendingPathComponent("\(item.id).payload")
        let tempURL = directory.appendingPathComponent("\(item.id).json.tmp")
        do {
            if let payload {
                try payload.write(to: payloadURL)
                item.payloadFile = payloadURL.lastPathComponent
            }
            try JSONEncoder().encode(item).write(to: tempURL)
            try FileManager.default.moveItem(at: tempURL, to: directory.appendingPathComponent("\(item.id).json"))
        } catch {
            try? FileManager.default.removeItem(at: payloadURL)
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    /// Imports every item, oldest first, through `ClipCapture` and the 10 s duplicate rule, then deletes its files.
    /// A corrupt or incomplete item is deleted and skipped. Saves once; returns the number of clips inserted.
    /// Pass the app's main context, so the sync tracker uploads the inserts.
    @MainActor static func drain(in context: ModelContext, directory: URL, now: Date) -> Int {
        let fm = FileManager.default
        let jsons = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        var pending: [(item: InboxItem, json: URL)] = []
        for json in jsons {
            guard let data = try? Data(contentsOf: json), let item = try? JSONDecoder().decode(InboxItem.self, from: data) else {
                remove(json, in: directory)
                continue
            }
            pending.append((item, json))
        }
        var inserted = 0
        for (item, json) in pending.sorted(by: { $0.item.createdAt < $1.item.createdAt }) {
            defer { remove(json, in: directory, payload: item.payloadFile) }
            guard let clip = capture(item, in: directory) else { continue }
            // A clip is never dated in the future, even if the phone's clock moved back since the share.
            let copiedAt = min(item.createdAt, now)
            // A failed check imports anyway: an extra row beats a lost clip.
            if (try? ClipCapture.isRecentDuplicate(hash: clip.contentHash, in: context, now: copiedAt)) == true { continue }
            let thumbnail = clip.contentType == .image ? Thumbnail.png(from: clip.rawData) : nil
            let clipItem = ClipboardItem(contentType: clip.contentType, rawData: clip.rawData, textContent: clip.textContent,
                                         thumbnailData: thumbnail, sourceAppName: item.source ?? "Share",
                                         contentHash: clip.contentHash)
            clipItem.copiedAt = copiedAt
            context.insert(clipItem)
            inserted += 1
        }
        try? context.save()
        return inserted
    }

    private static func capture(_ item: InboxItem, in directory: URL) -> CapturedClip? {
        switch item.kind {
        case .text:
            return item.text.flatMap(ClipCapture.text)
        case .image:
            // Last path component only: the name comes from a file, so it never reaches outside the inbox.
            guard let name = item.payloadFile.map({ ($0 as NSString).lastPathComponent }),
                  let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
            return ClipCapture.image(data)
        }
    }

    /// Deletes `<id>.json` and its payload. A corrupt JSON names no payload, so `<id>.payload` is removed by name.
    private static func remove(_ json: URL, in directory: URL, payload: String? = nil) {
        let fm = FileManager.default
        try? fm.removeItem(at: json)
        try? fm.removeItem(at: json.deletingPathExtension().appendingPathExtension("payload"))
        if let payload { try? fm.removeItem(at: directory.appendingPathComponent((payload as NSString).lastPathComponent)) }
    }
}
