import ImageIO
import UniformTypeIdentifiers
import XCTest

final class LatestClipActivityTests: XCTestCase {
    private typealias State = LatestClipActivity.ContentState

    private func item(_ type: ContentType, _ text: String?, thumbnail: Data? = nil) -> ClipboardItem {
        ClipboardItem(contentType: type, rawData: Data((text ?? "").utf8), textContent: text, thumbnailData: thumbnail,
                      sourceAppName: "Safari", contentHash: "h")
    }

    /// A PNG of `size` pixels: random noise, which compresses worst, or two flat rectangles, like a screenshot.
    private func png(size: Int, noise: Bool) throws -> Data {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if noise {
            var seed: UInt64 = 42
            let pixels = try XCTUnwrap(ctx.data).bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * size)
            for i in 0..<(ctx.bytesPerRow * size) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                pixels[i] = i % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: seed >> 33)
            }
        } else {
            ctx.setFillColor(red: 0, green: 0.6, blue: 0.7, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            ctx.setFillColor(red: 1, green: 0.8, blue: 0.2, alpha: 1)
            ctx.fill(CGRect(x: size / 4, y: size / 4, width: size / 2, height: size / 2))
        }
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    func testKinds() {
        XCTAssertEqual(State(item(.plainText, "hello")).kind, .text)
        XCTAssertEqual(State(item(.url, "https://copyd.app/a")).kind, .link)
        XCTAssertEqual(State(item(.plainText, "https://copyd.app/a")).kind, .link, "a bare link reads as a link")
        XCTAssertEqual(State(item(.color, "#F8D14F")).kind, .color)
        XCTAssertEqual(State(item(.image, nil)).kind, .image)
    }

    func testCarriesTheClipAndCapsThePreview() {
        let clip = item(.plainText, String(repeating: "x", count: 500))
        let state = State(clip)
        XCTAssertEqual(state.clipID, clip.id)
        XCTAssertEqual(state.source, "Safari")
        XCTAssertEqual(state.copiedAt, clip.copiedAt)
        XCTAssertEqual(state.preview, String(repeating: "x", count: 120))
        XCTAssertNil(state.thumbnail, "only images carry a thumbnail")
    }

    func testImageGetsATinyThumbnail() throws {
        let state = State(item(.image, nil, thumbnail: try png(size: 320, noise: false)))
        let thumb = try XCTUnwrap(state.thumbnail)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(thumb as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(max(image.width, image.height), 64)
        XCTAssertLessThanOrEqual(state.encodedSize, State.byteBudget)
    }

    /// ActivityKit drops an update whose encoded state passes 4 KB. The longest preview in bytes and a noise image,
    /// which no thumbnail can compress, must still fit.
    func testWorstCaseFitsTheBudget() throws {
        let text = State(item(.plainText, String(repeating: "\u{1F600}", count: 300)))
        XCTAssertLessThanOrEqual(text.encodedSize, State.byteBudget)
        let noise = State(item(.image, nil, thumbnail: try png(size: 320, noise: true)))
        XCTAssertLessThanOrEqual(noise.encodedSize, State.byteBudget)
        XCTAssertLessThan(State.byteBudget, 4096)
    }
}
