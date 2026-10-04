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
    /// The largest bundle sync accepts: `maxFiles` files at `maxFileBytes`, plus headroom for the manifest.
    static let maxBundleBytes = maxFiles * maxFileBytes + 1_048_576

    enum DecodeError: Error { case truncated, badManifest }

    static func encode(_ files: [(name: String, data: Data, uti: String)]) throws -> Data {
        let manifest = try JSONEncoder().encode(files.map { FileManifestEntry(name: $0.name, size: $0.data.count, uti: $0.uti) })
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
        guard let entries = try? JSONDecoder().decode([FileManifestEntry].self, from: data[start..<start + length]) else {
            throw DecodeError.badManifest
        }
        return (entries, data[(start + length)...])
    }

    /// The last path component without control characters, so a name from another device can't leave its folder.
    /// "file" when nothing usable is left, or when that is `.` or `..`.
    static func sanitize(_ name: String) -> String {
        let clean = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        let last = clean.split(separator: "/").last.map(String.init) ?? ""
        return ["", ".", ".."].contains(last) ? "file" : last
    }

    /// 1 to `maxFiles` files of at most `maxFileBytes` each. Anything else stays a local `.fileURL` clip.
    static func withinLimits(sizes: [Int]) -> Bool {
        !sizes.isEmpty && sizes.count <= maxFiles && sizes.allSatisfy { (0...maxFileBytes).contains($0) }
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
