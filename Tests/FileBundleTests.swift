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
        let max = FileBundle.maxFileBytes
        XCTAssertEqual(max, 20_971_520)
        XCTAssertEqual(FileBundle.maxFiles, 10)
        XCTAssertTrue(FileBundle.withinLimits(sizes: [max]))
        XCTAssertTrue(FileBundle.withinLimits(sizes: Array(repeating: max, count: 10)))
        XCTAssertFalse(FileBundle.withinLimits(sizes: [max + 1]))
        XCTAssertFalse(FileBundle.withinLimits(sizes: [25 * 1_048_576]), "one 25 MB file stays local")
        XCTAssertFalse(FileBundle.withinLimits(sizes: Array(repeating: 1, count: 11)), "11 files stay local")
        XCTAssertFalse(FileBundle.withinLimits(sizes: []))
        // The largest bundle within the limits is still one sync may upload.
        let biggest = FileBundle.maxFiles * FileBundle.maxFileBytes
        XCTAssertTrue(SyncRecordMapper.isEligible(contentType: ContentType.files.rawValue, byteCount: biggest + 4_096))
    }

    func testDecodeRejectsTruncated() throws {
        let bundle = try FileBundle.encode(files)
        XCTAssertThrowsError(try FileBundle.decode(bundle.dropLast()), "last byte missing")
        XCTAssertThrowsError(try FileBundle.decode(bundle + Data([0])), "trailing byte")
        XCTAssertThrowsError(try FileBundle.decode(bundle.prefix(3)), "header cut")
        XCTAssertThrowsError(try FileBundle.decode(bundle.prefix(20)), "manifest cut")
        XCTAssertThrowsError(try FileBundle.decode(Data()))
        // A manifest whose sizes run past the end, or go negative, never slices out of range.
        let negative = Data(#"[{"name":"a","size":-1,"uti":"public.data"}]"#.utf8)
        let header = withUnsafeBytes(of: UInt32(negative.count).bigEndian) { Data($0) }
        XCTAssertThrowsError(try FileBundle.decode(header + negative + Data([1])))
    }
}
