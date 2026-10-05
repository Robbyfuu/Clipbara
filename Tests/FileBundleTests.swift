import XCTest

final class FileBundleTests: XCTestCase {
    private let files: [(name: String, data: Data, uti: String)] = [
        (name: "Report.pdf", data: Data("pdf bytes".utf8), uti: "com.adobe.pdf"),
        (name: "empty.txt", data: Data(), uti: "public.plain-text"),
        (name: "Año 2026 ✓.png", data: Data((0..<300).map { UInt8($0 % 256) }), uti: "public.png"),
    ]

    private func assertSameFiles(_ a: [(name: String, data: Data, uti: String)],
                                 _ b: [(name: String, data: Data, uti: String)], line: UInt = #line) {
        XCTAssertEqual(a.map(\.name), b.map(\.name), line: line)
        XCTAssertEqual(a.map(\.data), b.map(\.data), line: line)
        XCTAssertEqual(a.map(\.uti), b.map(\.uti), line: line)
    }

    func testRoundTrip() throws {
        let bundle = try FileBundle.encode(files)
        assertSameFiles(try FileBundle.decode(bundle), files)
        XCTAssertEqual(try FileBundle.manifest(bundle).map(\.size), [9, 0, 300])
        // A bundle read back from a slice (non-zero start index) decodes the same.
        let padded = Data([0xFF]) + bundle
        assertSameFiles(try FileBundle.decode(padded[1...]), files)
    }

    func testSanitizesNames() {
        XCTAssertEqual(FileBundle.sanitize("Report.pdf"), "Report.pdf")
        XCTAssertEqual(FileBundle.sanitize("../../etc/passwd"), "passwd")
        XCTAssertEqual(FileBundle.sanitize("a/b/c.txt"), "c.txt")
        XCTAssertEqual(FileBundle.sanitize("/abs/path/"), "path")
        XCTAssertEqual(FileBundle.sanitize("/"), "file")
        XCTAssertEqual(FileBundle.sanitize(".."), "file")
        XCTAssertEqual(FileBundle.sanitize("."), "file")
        XCTAssertEqual(FileBundle.sanitize(""), "file")
        XCTAssertEqual(FileBundle.sanitize("x/.."), "file")
        XCTAssertEqual(FileBundle.sanitize(".\u{0}."), "file", "control characters cannot hide a ..")
        XCTAssertEqual(FileBundle.sanitize("bad\u{0}na\u{7}me\n.txt"), "badname.txt")
        XCTAssertEqual(FileBundle.sanitize("\u{1B}\u{7F}"), "file")
        XCTAssertEqual(FileBundle.sanitize("v1..2 notes.md"), "v1..2 notes.md", "dots inside a name are kept")
    }

    func testSanitizeTruncatesLongNamesKeepingTheExtension() {
        let long = FileBundle.sanitize(String(repeating: "a", count: 300) + ".pdf")
        XCTAssertEqual(long.utf8.count, 200)
        XCTAssertTrue(long.hasSuffix("a.pdf"))
        // Multi-byte characters are cut whole, never mid-sequence.
        let accented = FileBundle.sanitize(String(repeating: "é", count: 150) + ".txt")
        XCTAssertLessThanOrEqual(accented.utf8.count, 200)
        XCTAssertEqual(accented, String(repeating: "é", count: 98) + ".txt")
        // An extension too long to keep is cut with the rest.
        XCTAssertEqual(FileBundle.sanitize("a." + String(repeating: "x", count: 300)).utf8.count, 200)
        XCTAssertEqual(FileBundle.sanitize(String(repeating: "b", count: 300)).utf8.count, 200)
        // The " 2" suffix of a duplicate still fits under the 255-byte file name limit.
        XCTAssertEqual(FileBundle.sanitize(String(repeating: "c", count: 200) + ".txt").utf8.count, 200)
    }

    func testSanitizeNormalizesToNFC() {
        XCTAssertEqual(Array(FileBundle.sanitize("Cafe\u{301}.txt").utf8), Array("Caf\u{E9}.txt".utf8))
    }

    func testNamesThatDifferOnlyInNormalizationGetUniqueNFCNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try FileBundle.write(try FileBundle.encode([
            (name: "Cafe\u{301}.txt", data: Data("1".utf8), uti: "public.plain-text"),
            (name: "Caf\u{E9}.txt", data: Data("2".utf8), uti: "public.plain-text"),
        ]), to: root)
        // String equality is canonical: file URLs hand back the decomposed form the file system uses.
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Caf\u{E9}.txt", "Caf\u{E9} 2.txt"])
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, [Data("1".utf8), Data("2".utf8)])
    }

    func testWriteStaysInsideFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("clip", isDirectory: true)
        let hostile: [(name: String, data: Data, uti: String)] = [
            (name: "../escape.txt", data: Data("1".utf8), uti: "public.plain-text"),
            (name: "..", data: Data("2".utf8), uti: "public.data"),
            (name: "same.txt", data: Data("3".utf8), uti: "public.plain-text"),
            (name: "a/SAME.txt", data: Data("4".utf8), uti: "public.plain-text"),
        ]
        let urls = try FileBundle.write(try FileBundle.encode(hostile), to: dir)

        XCTAssertEqual(urls.map(\.lastPathComponent), ["escape.txt", "file", "same.txt", "SAME 2.txt"])
        for url in urls { XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["clip"])
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, hostile.map(\.data))

        // A second paste reuses what is already there instead of writing again.
        try Data("kept".utf8).write(to: urls[0])
        XCTAssertEqual(try FileBundle.write(try FileBundle.encode(hostile), to: dir), urls)
        XCTAssertEqual(try Data(contentsOf: urls[0]), Data("kept".utf8))
    }

    func testLimits() {
        let max = FileBundle.maxFileBytes, mb = 1_048_576
        XCTAssertEqual(max, 20_971_520)
        XCTAssertEqual(FileBundle.maxFiles, 10)
        XCTAssertEqual(FileBundle.maxTotalBytes, 48 * mb)
        XCTAssertTrue(FileBundle.withinLimits(sizes: [max]))
        XCTAssertFalse(FileBundle.withinLimits(sizes: [max + 1]))
        XCTAssertFalse(FileBundle.withinLimits(sizes: [25 * mb]), "one 25 MB file stays local")
        XCTAssertFalse(FileBundle.withinLimits(sizes: Array(repeating: 1, count: 11)), "11 files stay local")
        XCTAssertFalse(FileBundle.withinLimits(sizes: []))
        // 48 MB in total, so a clip fits in one CloudKit batch and under the 50 MB asset limit.
        XCTAssertTrue(FileBundle.withinLimits(sizes: [20 * mb, 20 * mb, 8 * mb]))
        XCTAssertFalse(FileBundle.withinLimits(sizes: [20 * mb, 20 * mb, 9 * mb]))
        XCTAssertFalse(FileBundle.withinLimits(sizes: Array(repeating: max, count: 10)))
        XCTAssertLessThanOrEqual(FileBundle.maxBundleBytes, 52_428_800)
        // The largest bundle within the limits is still one sync may upload.
        XCTAssertTrue(SyncRecordMapper.isEligible(contentType: ContentType.files.rawValue,
                                                  byteCount: FileBundle.maxTotalBytes + 4_096))
    }

    private func assertThrows(_ expected: FileBundle.DecodeError, _ data: Data, _ message: String,
                              line: UInt = #line) {
        XCTAssertThrowsError(try FileBundle.decode(data), message, line: line) {
            XCTAssertEqual($0 as? FileBundle.DecodeError, expected, message, line: line)
        }
        XCTAssertThrowsError(try FileBundle.manifest(data), message, line: line) {
            XCTAssertEqual($0 as? FileBundle.DecodeError, expected, message, line: line)
        }
    }

    private func bundle(manifestJSON json: String, body: Data = Data()) -> Data {
        let manifest = Data(json.utf8)
        return withUnsafeBytes(of: UInt32(manifest.count).bigEndian) { Data($0) } + manifest + body
    }

    func testDecodeRejectsTruncated() throws {
        let bundle = try FileBundle.encode(files)
        assertThrows(.truncated, bundle.dropLast(), "last byte missing")
        assertThrows(.truncated, bundle + Data([0]), "trailing byte")
        assertThrows(.truncated, bundle.prefix(3), "header cut")
        assertThrows(.truncated, bundle.prefix(20), "manifest cut")
        assertThrows(.truncated, Data(), "empty")
        // A manifest whose sizes run past the end, or go negative, never slices out of range.
        assertThrows(.truncated, self.bundle(manifestJSON: #"[{"name":"a","size":-1,"uti":"public.data"}]"#, body: Data([1])),
                     "negative size")
        assertThrows(.truncated, self.bundle(manifestJSON: "[{\"name\":\"a\",\"size\":\(Int.max),\"uti\":\"public.data\"}]",
                                             body: Data([1])), "Int.max size")
        assertThrows(.badManifest, self.bundle(manifestJSON: "not json", body: Data([1])), "invalid JSON")
    }

    func testRejectsMoreThanMaxFiles() throws {
        let eleven = (0...FileBundle.maxFiles).map { (name: "\($0).txt", data: Data([1]), uti: "public.plain-text") }
        assertThrows(.badManifest, try FileBundle.encode(eleven), "11 files")
        XCTAssertEqual(try FileBundle.manifest(try FileBundle.encode(Array(eleven.dropLast()))).count, FileBundle.maxFiles)
    }

    func testManifestJSONIsTheManifest() throws {
        let json = try XCTUnwrap(FileBundle.manifestJSON(try FileBundle.encode(files)))
        let entries = try JSONDecoder().decode([FileManifestEntry].self, from: json)
        XCTAssertEqual(entries, try FileBundle.manifest(try FileBundle.encode(files)))
        XCTAssertEqual(FileBundle.manifestJSON(try FileBundle.encode(files)), json, "same bytes every time")
        XCTAssertNil(FileBundle.manifestJSON(Data("not a bundle".utf8)))
    }

    func testReusableKeepsURLsOnlyWhileEveryFileExists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try FileBundle.write(try FileBundle.encode(files), to: root)
        XCTAssertEqual(FileBundle.reusable(urls), urls)
        XCTAssertNil(FileBundle.reusable(nil))
        try FileManager.default.removeItem(at: urls[1])
        XCTAssertNil(FileBundle.reusable(urls), "one file gone: write again")
    }

    func testOnlyLocalDownloadedFilesAreRead() {
        XCTAssertTrue(FileBundle.isLocal(downloadingStatus: nil, volumeIsLocal: true))
        XCTAssertTrue(FileBundle.isLocal(downloadingStatus: nil, volumeIsLocal: nil))
        XCTAssertTrue(FileBundle.isLocal(downloadingStatus: .current, volumeIsLocal: true))
        XCTAssertFalse(FileBundle.isLocal(downloadingStatus: .notDownloaded, volumeIsLocal: true), "iCloud Drive, not downloaded")
        XCTAssertFalse(FileBundle.isLocal(downloadingStatus: .downloaded, volumeIsLocal: true), "an older version")
        XCTAssertFalse(FileBundle.isLocal(downloadingStatus: nil, volumeIsLocal: false), "network volume")
    }

    func testRemovesFoldersOfClipsThatAreGone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = UUID(), gone = UUID()
        for name in [kept.uuidString, gone.uuidString, "notes"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        struct FetchFailed: Error {}
        FileBundle.removeOrphanFolders(in: root) { throw FetchFailed() }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
                       [kept.uuidString, gone.uuidString, "notes"], "a failed fetch removes nothing")

        FileBundle.removeOrphanFolders(in: root) { Set([kept]) }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), [kept.uuidString, "notes"])
        FileBundle.removeOrphanFolders(in: root.appendingPathComponent("missing")) { [] }  // no Files folder yet
    }
}
