import AppKit
import OSLog
import SwiftData

@MainActor
struct PasteService {

    private static let tempDir = NSTemporaryDirectory() + "Copyd/"
    private static let log = Logger(subsystem: "com.robbyfuu.copyd", category: "Paste")

    nonisolated private static let filesRoot = URL.applicationSupportDirectory
        .appendingPathComponent("Copyd/Files", isDirectory: true)

    /// Where a file clip's files are written to be pasted: `Application Support/Copyd/Files/<clip-id>/`.
    nonisolated static func filesDirectory(for id: UUID) -> URL {
        filesRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// The URLs each file clip's files were last written to, so a Paste Stack re-stage never reads the bundle again.
    private static var writtenFiles: [UUID: [URL]] = [:]

    /// Removes a file clip's folder when the clip is deleted, whatever deletes it: the panel, the history limit or sync.
    /// Runs on the main context's saves, as `LocalChangeTracker` does.
    static func removeFilesOnDelete(in context: ModelContext) {
        // Read only inside assumeIsolated: the main context posts willSave synchronously on the main thread.
        nonisolated(unsafe) let context = context
        _ = NotificationCenter.default.addObserver(forName: ModelContext.willSave, object: context, queue: nil) { _ in
            MainActor.assumeIsolated {
                for case let clip as ClipboardItem in context.deletedModelsArray where clip.contentTypeRaw == ContentType.files.rawValue {
                    writtenFiles[clip.id] = nil
                    try? FileManager.default.removeItem(at: filesDirectory(for: clip.id))
                }
            }
        }
    }

    /// Removes the `Files/<id>/` folders of clips that no longer exist, such as ones deleted by a build without the
    /// observer above. Runs in the background once the store is open.
    nonisolated static func removeOrphanFiles(in container: ModelContainer) {
        Task.detached(priority: .utility) {
            FileBundle.removeOrphanFolders(in: filesRoot) {
                let files = ContentType.files.rawValue
                let clips = try ModelContext(container).fetch(FetchDescriptor<ClipboardItem>(
                    predicate: #Predicate { $0.contentTypeRaw == files }))
                return Set(clips.map(\.id))
            }
        }
    }

    /// Backing key for the "Always Paste as Plain Text" setting (Settings > General).
    nonisolated static let alwaysPlainTextDefaultsKey = "alwaysPastePlainText"

    /// Whether stripping formatting is meaningful for this item (RTF/HTML only).
    static func supportsPlainText(_ item: ClipboardItem) -> Bool {
        switch item.contentType {
        case .richText, .html:
            return !(item.textContent?.isEmpty ?? true)
        default:
            return false
        }
    }

    /// Combines the setting with the Shift modifier using XOR.
    /// Setting off: Shift strips formatting. Setting on: Shift keeps formatting.
    static func resolvePlainText() -> Bool {
        let always = UserDefaults.standard.bool(forKey: alwaysPlainTextDefaultsKey)
        let shiftHeld = NSEvent.modifierFlags.contains(.shift)
        return always != shiftHeld
    }

    /// - Parameter asPlainText: `nil` resolves from the setting combined with the Shift modifier.
    /// - Parameter recordPaste: `false` for Paste Stack staging, which only prepares the pasteboard.
    func paste(item: ClipboardItem, asPlainText: Bool? = nil, recordPaste: Bool = true) {
        if recordPaste { ReviewPrompter.recordPaste() }
        if asPlainText ?? Self.resolvePlainText(), Self.supportsPlainText(item) {
            pastePlainText(item: item)
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.contentType {
        case .plainText, .html, .richText:
            if let text = item.textContent {
                pasteboard.setString(text, forType: .string)
            }
            // Also set original format for rich text / HTML
            if item.contentType == .richText {
                pasteboard.setData(item.rawData, forType: .rtf)
            } else if item.contentType == .html {
                pasteboard.setData(item.rawData, forType: .html)
            }

        case .image:
            guard let image = NSImage(data: item.rawData),
                  let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                pasteboard.setData(item.rawData, forType: .tiff)
                break
            }

            // 임시 PNG 파일 저장 — 터미널 앱(Ghostty 등)이 파일 경로로 이미지를 전달
            let tempURL = Self.writeTempPNG(pngData, sourceApp: item.sourceAppName)

            // NSURL writeObjects로 파일 URL을 먼저 쓴 뒤 PNG/TIFF 추가
            // — Ghostty가 이미지 파일로 인식하려면 이 순서가 필요
            if let tempURL {
                pasteboard.writeObjects([tempURL as NSURL])
            }
            pasteboard.setData(pngData, forType: .png)
            pasteboard.setData(tiffData, forType: .tiff)

        case .url:
            if let text = item.textContent {
                pasteboard.setString(text, forType: .string)
                if let url = URL(string: text) {
                    pasteboard.setString(url.absoluteString, forType: .URL)
                }
            }

        case .fileURL:
            if let text = item.textContent,
               let urlString = String(data: item.rawData, encoding: .utf8) {
                pasteboard.setString(urlString, forType: .fileURL)
                pasteboard.setString(text, forType: .string)
            }

        case .files:
            // Written on the first paste and reused while the files are there: Paste Stack staging reads no rawData.
            do {
                let urls = try FileBundle.reusable(Self.writtenFiles[item.id])
                    ?? FileBundle.write(item.rawData, to: Self.filesDirectory(for: item.id))
                Self.writtenFiles[item.id] = urls
                pasteboard.writeObjects(urls.map { $0 as NSURL })
            } catch {
                Self.log.error("Files of \(item.id, privacy: .public) not written: \(error.localizedDescription, privacy: .public)")
            }

        case .color:
            if let text = item.textContent {
                pasteboard.setString(text, forType: .string)
            }

        case .unknown:
            pasteboard.setData(item.rawData, forType: .string)
        }
    }

    func pastePlainText(item: ClipboardItem) {
        guard let text = item.textContent else { return }
        pastePlainText(text)
    }

    /// - Parameter rtf: "Paste as → Formatted text": its RTF, written beside the plain text for apps that take formatting.
    func pastePlainText(_ text: String, rtf: Data? = nil) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if let rtf { pasteboard.setData(rtf, forType: .rtf) }
    }

    /// 오래된 임시 파일 정리 (1시간 이상)
    func cleanupTempFiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: Self.tempDir) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for file in files {
            let path = Self.tempDir + file
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let modified = attrs[.modificationDate] as? Date,
                  modified < cutoff else { continue }
            try? fm.removeItem(atPath: path)
        }
    }

    private static let filenameDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    private static func writeTempPNG(_ data: Data, sourceApp: String?) -> URL? {
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        let asciiOnly = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_")
        let safeName = sourceApp?
            .unicodeScalars.filter { asciiOnly.contains($0) }
            .reduce(into: "") { $0.append(String($1)) }
            .trimmingCharacters(in: .whitespaces)
        let appName = (safeName?.isEmpty ?? true) ? "Copyd" : safeName!
        let timestamp = filenameDateFormatter.string(from: Date())
        let filename = "\(appName) \(timestamp).png" as String
        let url = URL(fileURLWithPath: tempDir + filename)
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
