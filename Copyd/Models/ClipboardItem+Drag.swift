import AppKit
import SwiftData
import UniformTypeIdentifiers

extension ClipboardItem {
    func dragProvider() -> NSItemProvider {
        let provider: NSItemProvider

        switch contentType {
        // ponytail: a file bundle drags as its names; paste puts the files themselves on the pasteboard.
        case .plainText, .richText, .html, .unknown, .files:
            provider = NSItemProvider(object: (textContent ?? "") as NSString)

        case .image:
            if let image = NSImage(data: rawData),
               let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Copyd", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let asciiOnly = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_")
                let safeName = sourceAppName?
                    .unicodeScalars.filter { asciiOnly.contains($0) }
                    .reduce(into: "") { $0.append(String($1)) }
                    .trimmingCharacters(in: .whitespaces)
                let appName = (safeName?.isEmpty ?? true) ? "Copyd" : safeName!
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
                let filename = "\(appName) \(formatter.string(from: copiedAt)).png"
                let fileURL = dir.appendingPathComponent(filename)
                try? pngData.write(to: fileURL)
                provider = NSItemProvider(contentsOf: fileURL) ?? NSItemProvider(object: image)
            } else {
                provider = NSItemProvider()
            }

        case .url:
            if let text = textContent, let url = URL(string: text) {
                provider = NSItemProvider(object: url as NSURL)
            } else {
                provider = NSItemProvider(object: (textContent ?? "") as NSString)
            }

        case .fileURL:
            if let text = textContent, let url = URL(string: text) {
                provider = NSItemProvider(object: url as NSURL)
            } else {
                provider = NSItemProvider()
            }

        case .color:
            provider = NSItemProvider(object: (textContent ?? "") as NSString)
        }

        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.copydClipboardItemID.identifier,
            visibility: .ownProcess
        ) { [id] completion in
            completion(id.uuidString.data(using: .utf8), nil)
            return nil
        }

        return provider
    }
}

extension UTType {
    static let copydClipboardItemID = UTType(exportedAs: "com.robbyfuu.copyd.clipboard-item-id")
}
