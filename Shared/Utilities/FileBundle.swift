import Foundation

struct FileManifestEntry: Codable, Equatable, Sendable {
    var name: String
    var size: Int
    var uti: String
}

/// Copied files as one blob, the `rawData` of a `.files` clip:
/// `[UInt32 big-endian manifest length][manifest JSON: [FileManifestEntry]][file bytes, in manifest order]`.
/// Each file's offset is the sum of the sizes before it. Names are stored as copied and sanitized only on write.
enum FileBundle {
    static let maxFileBytes = 20_971_520
    static let maxFiles = 10
    /// 48 MB of file data in all, so one clip fits in a CloudKit batch and under the 50 MB asset limit.
    static let maxTotalBytes = 50_331_648
    /// The largest bundle sync accepts: `maxTotalBytes` plus headroom for the manifest.
    static let maxBundleBytes = maxTotalBytes + 1_048_576
    /// A sanitized name's limit, so a " 2" suffix still fits under the 255-byte file name limit.
    private static let maxNameBytes = 200

    enum DecodeError: Error { case truncated, badManifest }

    static func encode(_ files: [(name: String, data: Data, uti: String)]) throws -> Data {
        let manifest = try json(files.map { FileManifestEntry(name: $0.name, size: $0.data.count, uti: $0.uti) })
        var out = withUnsafeBytes(of: UInt32(manifest.count).bigEndian) { Data($0) }
        out.reserveCapacity(4 + manifest.count + files.reduce(0) { $0 + $1.data.count })
        out.append(manifest)
        for file in files { out.append(file.data) }
        return out
    }

    /// The files' bytes are slices of `data`, not copies.
    static func decode(_ data: Data) throws -> [(name: String, data: Data, uti: String)] {
        let entries = try manifest(data)
        // The sizes cover the bytes after the manifest exactly, so the first file starts at end minus their sum.
        var offset = data.endIndex - entries.reduce(0) { $0 + $1.size }
        return entries.map { entry in
            defer { offset += entry.size }
            return (entry.name, data[offset..<offset + entry.size], entry.uti)
        }
    }

    /// Names, sizes and types, without touching the file bytes. Throws unless the sizes cover the bytes exactly.
    static func manifest(_ data: Data) throws -> [FileManifestEntry] {
        let (entries, body) = try split(data)
        var left = body.count
        for entry in entries {
            guard entry.size >= 0, entry.size <= left else { throw DecodeError.truncated }
            left -= entry.size
        }
        guard left == 0 else { throw DecodeError.truncated }
        return entries
    }

    private static func split(_ data: Data) throws -> (entries: [FileManifestEntry], body: Data) {
        guard data.count >= 4 else { throw DecodeError.truncated }
        let length = Int(data.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        let start = data.startIndex + 4
        guard length <= data.endIndex - start else { throw DecodeError.truncated }
        guard let entries = try? JSONDecoder().decode([FileManifestEntry].self, from: data[start..<start + length]),
              entries.count <= maxFiles else {
            throw DecodeError.badManifest
        }
        return (entries, data[(start + length)...])
    }

    /// The manifest as JSON, the same bytes for the same files: what a `.files` clip keeps in `fileManifestData`
    /// and sync sends as `fileManifest`. Nil when `bundle` is not a valid bundle.
    static func manifestJSON(_ bundle: Data) -> Data? {
        (try? manifest(bundle)).flatMap { try? json($0) }
    }

    private static func json(_ entries: [FileManifestEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(entries)
    }

    /// The last path component without control characters, so a name from another device can't leave its folder.
    /// NFC, and at most `maxNameBytes` UTF-8 bytes, keeping the extension unless it alone takes half of them.
    /// "file" when nothing usable is left, or when that is `.` or `..`.
    static func sanitize(_ name: String) -> String {
        let clean = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .precomposedStringWithCanonicalMapping
        let last = clean.split(separator: "/").last.map(String.init) ?? ""
        let ext = (last as NSString).pathExtension
        let short = ext.isEmpty || ext.utf8.count >= maxNameBytes / 2
            ? prefix(last, bytes: maxNameBytes)
            : prefix((last as NSString).deletingPathExtension, bytes: maxNameBytes - ext.utf8.count - 1) + "." + ext
        return ["", ".", ".."].contains(short) ? "file" : short
    }

    /// Whole characters only, so no UTF-8 sequence is cut.
    private static func prefix(_ s: String, bytes limit: Int) -> String {
        var out = "", used = 0
        for c in s {
            used += c.utf8.count
            if used > limit { break }
            out.append(c)
        }
        return out
    }

    /// 1 to `maxFiles` files of at most `maxFileBytes` each and `maxTotalBytes` in all.
    /// Anything else stays a local `.fileURL` clip.
    static func withinLimits(sizes: [Int]) -> Bool {
        !sizes.isEmpty && sizes.count <= maxFiles && sizes.allSatisfy { (0...maxFileBytes).contains($0) }
            && sizes.reduce(0, +) <= maxTotalBytes
    }

    /// A file still in iCloud Drive, or an older version of one, or a file on a network volume would download or
    /// block on read, so it stays a local `.fileURL` clip.
    static func isLocal(downloadingStatus: URLUbiquitousItemDownloadingStatus?, volumeIsLocal: Bool?) -> Bool {
        (downloadingStatus == nil || downloadingStatus == .current) && volumeIsLocal != false
    }

    /// `urls` from an earlier write while every file is still there, so pasting again reads nothing.
    static func reusable(_ urls: [URL]?) -> [URL]? {
        guard let urls, urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        return urls
    }

    /// Removes the `<clip-id>` folders in `root` whose id `liveIDs` doesn't return. The folders are listed first,
    /// so a clip saved meanwhile is in `liveIDs`. A throwing `liveIDs` removes nothing; other names are left alone.
    static func removeOrphanFolders(in root: URL, keeping liveIDs: () throws -> Set<UUID>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path), !names.isEmpty,
              let live = try? liveIDs() else { return }
        for name in names {
            guard let id = UUID(uuidString: name), !live.contains(id) else { continue }
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// Writes the files into `directory` under sanitized names, made unique ("a 2.txt"), and returns their URLs
    /// in bundle order. A file already there is kept, so pasting the same clip again writes nothing.
    static func write(_ bundle: Data, to directory: URL) throws -> [URL] {
        let files = try decode(bundle)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var used: Set<String> = []
        return try files.map { file in
            let url = directory.appendingPathComponent(unique(sanitize(file.name), &used), isDirectory: false)
            if !fm.fileExists(atPath: url.path) { try file.data.write(to: url, options: .atomic) }
            return url
        }
    }

    /// Case-insensitive, as APFS is by default.
    private static func unique(_ name: String, _ used: inout Set<String>) -> String {
        let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
        var candidate = name, n = 1
        while used.contains(candidate.lowercased()) {
            n += 1
            candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
        }
        used.insert(candidate.lowercased())
        return candidate
    }
}
