import XCTest

/// The MCP server's incremental HTTP/1.1 parser: limits, partial reads, and the framing it refuses.
final class HTTPRequestParserTests: XCTestCase {
    private func request(_ head: String, body: String = "") -> Data {
        Data((head.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n" + body).utf8)
    }

    private let post = "POST /mcp HTTP/1.1\nHost: 127.0.0.1:39787\nContent-Length: 2\n"

    func testParsesACompletePost() {
        var parser = HTTPRequestParser()
        guard case .complete(let req) = parser.feed(request(post, body: "{}")) else { return XCTFail("expected a request") }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/mcp")
        XCTAssertEqual(req.header("host"), "127.0.0.1:39787")
        XCTAssertEqual(req.header("HOST"), "127.0.0.1:39787", "header names are case-insensitive")
        XCTAssertEqual(req.body, Data("{}".utf8))
    }

    func testDropsTheQueryFromThePath() {
        var parser = HTTPRequestParser()
        guard case .complete(let req) = parser.feed(request("GET /mcp?x=1 HTTP/1.1\nHost: a\n")) else { return XCTFail() }
        XCTAssertEqual(req.path, "/mcp")
    }

    func testWaitsForTheRestOfASplitRequest() {
        var parser = HTTPRequestParser()
        let bytes = request(post, body: "{}")
        for i in 0..<(bytes.count - 1) {
            XCTAssertEqual(parser.feed(bytes.subdata(in: i..<(i + 1))), .incomplete, "byte \(i) alone completes nothing")
        }
        guard case .complete(let req) = parser.feed(bytes.suffix(1)) else { return XCTFail("the last byte completes it") }
        XCTAssertEqual(req.body, Data("{}".utf8))
    }

    func testKeepsPipelinedBytesForTheNextRequest() {
        var parser = HTTPRequestParser()
        var both = request(post, body: "{}")
        both.append(request(post, body: "[]"))
        guard case .complete(let first) = parser.feed(both) else { return XCTFail() }
        XCTAssertEqual(first.body, Data("{}".utf8))
        guard case .complete(let second) = parser.feed(Data()) else { return XCTFail("the leftover is a whole request") }
        XCTAssertEqual(second.body, Data("[]".utf8))
        XCTAssertEqual(parser.feed(Data()), .incomplete)
    }

    func testPostWithoutContentLengthNeedsALength() {
        var parser = HTTPRequestParser()
        XCTAssertEqual(parser.feed(request("POST /mcp HTTP/1.1\nHost: a\n")), .failure(411))
    }

    func testChunkedBodiesAreRefused() {
        var parser = HTTPRequestParser()
        XCTAssertEqual(parser.feed(request("POST /mcp HTTP/1.1\nHost: a\nTransfer-Encoding: chunked\n", body: "2\r\n{}\r\n0\r\n\r\n")),
                       .failure(411))
        var both = HTTPRequestParser()
        XCTAssertEqual(both.feed(request(post + "Transfer-Encoding: chunked\n", body: "{}")), .failure(411),
                       "Content-Length plus Transfer-Encoding is a smuggling attempt")
    }

    func testABodyOverOneMegabyteIs413BeforeItArrives() {
        var parser = HTTPRequestParser()
        let tooBig = HTTPRequestParser.maxBodyBytes + 1
        XCTAssertEqual(parser.feed(request("POST /mcp HTTP/1.1\nHost: a\nContent-Length: \(tooBig)\n")), .failure(413))
    }

    func testABodyOfExactlyOneMegabyteIsAccepted() {
        var parser = HTTPRequestParser()
        let size = HTTPRequestParser.maxBodyBytes
        let body = String(repeating: "a", count: size)
        guard case .complete(let req) = parser.feed(request("POST /mcp HTTP/1.1\nHost: a\nContent-Length: \(size)\n", body: body))
        else { return XCTFail() }
        XCTAssertEqual(req.body.count, size)
    }

    func testAHeaderBlockOver16KBIs431EvenUnfinished() {
        var parser = HTTPRequestParser()
        let filler = "X-Filler: " + String(repeating: "a", count: HTTPRequestParser.maxHeaderBytes) + "\r\n"
        XCTAssertEqual(parser.feed(Data(("POST /mcp HTTP/1.1\r\n" + filler).utf8)), .failure(431),
                       "a client that never ends its headers must not grow the buffer")
    }

    func testMalformedContentLengthIs400() {
        for value in ["abc", "-1", "1 2", "+5", ""] {
            var parser = HTTPRequestParser()
            XCTAssertEqual(parser.feed(request("POST /mcp HTTP/1.1\nHost: a\nContent-Length: \(value)\n")), .failure(400), value)
        }
    }

    func testDuplicateSecurityHeadersAre400() {
        for name in ["Host", "Content-Length", "Authorization", "Origin"] {
            var parser = HTTPRequestParser()
            let head = "POST /mcp HTTP/1.1\nHost: a\nContent-Length: 0\nAuthorization: Bearer x\nOrigin: http://a\n\(name): b\n"
            XCTAssertEqual(parser.feed(request(head)), .failure(400), name)
        }
    }

    func testGarbageIs400() {
        for head in ["NONSENSE\n", "POST /mcp\n", "POST /mcp HTTP/1.1\nNoColonHere\n", "POST /mcp HTTP/1.1\n folded: x\n",
                     "POST /mcp HTTP/1.1\nBad Name: x\n", "POST mcp HTTP/1.1\nHost: a\n", "POST /mcp FTP/1.0\nHost: a\n"] {
            var parser = HTTPRequestParser()
            XCTAssertEqual(parser.feed(request(head)), .failure(400), head)
        }
    }

    func testAsksToCloseWhenTheClientSaysSo() {
        var parser = HTTPRequestParser()
        guard case .complete(let req) = parser.feed(request("GET /mcp HTTP/1.1\nHost: a\nConnection: close\n")) else { return XCTFail() }
        XCTAssertFalse(req.keepAlive)
        var other = HTTPRequestParser()
        guard case .complete(let kept) = other.feed(request("GET /mcp HTTP/1.1\nHost: a\n")) else { return XCTFail() }
        XCTAssertTrue(kept.keepAlive)
    }
}
