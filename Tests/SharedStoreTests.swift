import XCTest

final class SharedStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testURLShape() {
        let url = SharedStore.url(groupContainer: root)
        XCTAssertEqual(url.path, root.appendingPathComponent("Library/Application Support/Copyd/Copyd.store").path)
    }

    func testURLCreatesDirectory() {
        let url = SharedStore.url(groupContainer: root)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testStoreExistsIsFalseWithoutFile() {
        XCTAssertFalse(SharedStore.storeExists(groupContainer: root))
        let dir = root.appendingPathComponent("Library/Application Support/Copyd")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "storeExists must not create anything")
    }

    func testStoreExistsIsTrueAfterFileCreated() {
        let url = SharedStore.url(groupContainer: root)
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        XCTAssertTrue(SharedStore.storeExists(groupContainer: root))
    }
}
