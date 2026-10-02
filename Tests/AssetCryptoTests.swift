import XCTest

final class AssetCryptoTests: XCTestCase {
    private func randomData(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    func testMakeKeyIs32Bytes() {
        XCTAssertEqual(AssetCrypto.makeKey().count, 32)
    }

    func testRoundTrip() throws {
        let key = AssetCrypto.makeKey()
        let plain = randomData(1_000_000)
        let sealed = try AssetCrypto.seal(plain, key: key)
        XCTAssertEqual(try AssetCrypto.open(sealed, key: key), plain)
    }

    func testSealedDiffersFromPlaintext() throws {
        let plain = randomData(1024)
        XCTAssertNotEqual(try AssetCrypto.seal(plain, key: AssetCrypto.makeKey()), plain)
    }

    func testOpenFailsWithWrongKey() throws {
        let sealed = try AssetCrypto.seal(randomData(1024), key: AssetCrypto.makeKey())
        XCTAssertThrowsError(try AssetCrypto.open(sealed, key: AssetCrypto.makeKey()))
    }

    func testOpenFailsWhenTampered() throws {
        let key = AssetCrypto.makeKey()
        var sealed = try AssetCrypto.seal(randomData(1024), key: key)
        sealed[sealed.count / 2] ^= 0xFF
        XCTAssertThrowsError(try AssetCrypto.open(sealed, key: key))
    }
}
