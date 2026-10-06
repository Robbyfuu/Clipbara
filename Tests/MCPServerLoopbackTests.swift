import Network
import XCTest

/// A bare TCP client for what URLSession cannot send: a forged Host, headers without their body, or nothing at all.
final class RawHTTPClient: @unchecked Sendable {
    enum Outcome: Equatable { case response(String), closed, timedOut }

    // Confined to `queue`.
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "RawHTTPClient")
    private var buffer = Data()
    private var waiter: CheckedContinuation<Outcome, Never>?
    private var reads = 0

    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: queue)
    }

    func send(_ text: String) {
        connection.send(content: Data(text.utf8), completion: .idempotent)
    }

    /// One whole response (head plus `Content-Length` body), or `.closed` when the server hangs up first.
    func read(timeout: TimeInterval = 5) async -> Outcome {
        await withCheckedContinuation { continuation in
            queue.async {
                self.reads += 1
                let read = self.reads
                self.waiter = continuation
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    if self.reads == read { self.finish(.timedOut) }
                }
                self.receive()
            }
        }
    }

    func cancel() { connection.cancel() }

    private func finish(_ outcome: Outcome) {
        waiter?.resume(returning: outcome)
        waiter = nil
    }

    private func receive() {
        if let whole = completeResponse() { return finish(.response(whole)) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if let data { self.buffer.append(data) }
            if let whole = self.completeResponse() { return self.finish(.response(whole)) }
            if isComplete || error != nil { return self.finish(.closed) }
            self.receive()
        }
    }

    private func completeResponse() -> String? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        guard buffer.count >= end.upperBound + length else { return nil }
        let whole = String(decoding: buffer[..<(end.upperBound + length)], as: UTF8.self)
        buffer.removeSubrange(..<(end.upperBound + length))
        return whole
    }
}

/// The real server on an ephemeral loopback port, inside the unhosted test process. Every test stops it.
final class MCPServerLoopbackTests: XCTestCase {
    private let token = "loopback-test-token"
    private var server: MCPServer!
    private var port: UInt16 = 0
    private let session = URLSession(configuration: .ephemeral)
    private let library = FakeClipLibrary()

    private func startServer(idleTimeout: TimeInterval = 30, maxConnections: Int = 8) async throws {
        server = MCPServer(port: 0, token: token, router: MCPRouter(library: library, allowsWrite: { false }),
                           idleTimeout: idleTimeout, maxConnections: maxConnections)
        let running = expectation(description: "running")
        let box = PortBox()
        server.onStateChange = { state in
            if case .running(let port) = state, box.set(port) { running.fulfill() }
        }
        let started = server!
        addTeardownBlock { started.stop() }
        try server.start()
        await fulfillment(of: [running], timeout: 5)
        port = box.port
        XCTAssertNotEqual(port, 0, "an ephemeral port is reported once bound")
    }

    private func request(_ method: String = "POST", path: String = "/mcp", body: String? = nil,
                         headers: [String: String] = [:], authorized: Bool = true) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if authorized { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body { request.httpBody = Data(body.utf8) }
        return request
    }

    private func status(_ request: URLRequest) async throws -> (Int, HTTPURLResponse, Data) {
        let (data, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return (http.statusCode, http, data)
    }

    private let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#
    private let ping = #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#

    private func rawPing(host: String? = nil, connection: String = "keep-alive") -> String {
        let host = host ?? "127.0.0.1:\(port)"
        return "POST /mcp HTTP/1.1\r\nHost: \(host)\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\n"
            + "Connection: \(connection)\r\nContent-Length: \(ping.utf8.count)\r\n\r\n\(ping)"
    }

    // MARK: state

    func testReportsRunningOnTheBoundPortAndOffAfterStop() async throws {
        try await startServer()
        XCTAssertEqual(server.state, .running(port))
        let off = expectation(description: "off")
        server.onStateChange = { if $0 == .off { off.fulfill() } }
        server.stop()
        await fulfillment(of: [off], timeout: 5)
        XCTAssertEqual(server.state, .off)
    }

    func testABusyPortFails() async throws {
        try await startServer()
        let second = MCPServer(port: port, token: token, router: MCPRouter(library: library, allowsWrite: { false }))
        addTeardownBlock { second.stop() }
        let failed = expectation(description: "failed")
        second.onStateChange = { if case .failed = $0 { failed.fulfill() } }
        try second.start()
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertEqual(second.state, .failed("Port \(port) is in use"))
    }

    // MARK: HTTP statuses

    func testInitializeAnswers200WithJSONAndASessionId() async throws {
        try await startServer()
        let (code, response, data) = try await status(request(body: initialize))
        XCTAssertEqual(code, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertFalse((response.value(forHTTPHeaderField: "Mcp-Session-Id") ?? "").isEmpty)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((json["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
    }

    func testToolsCallRoundTripsThroughTheLibrary() async throws {
        try await startServer()
        let body = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_clips","arguments":{"query":"x"}}}"#
        let (code, _, data) = try await status(request(body: body, headers: ["Mcp-Session-Id": "abc", "MCP-Protocol-Version": "2025-06-18"]))
        XCTAssertEqual(code, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((json["result"] as? [String: Any])?["isError"] as? Bool, false)
        let searches = await library.searches
        XCTAssertEqual(searches.first?.query, "x")
    }

    func testANotificationIs202WithNoBody() async throws {
        try await startServer()
        let (code, _, data) = try await status(request(body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertEqual(code, 202)
        XCTAssertTrue(data.isEmpty)
    }

    func testAMissingOrWrongTokenIs401() async throws {
        try await startServer()
        let (missing, _, _) = try await status(request(body: ping, authorized: false))
        XCTAssertEqual(missing, 401)
        let (wrong, _, _) = try await status(request(body: ping, headers: ["Authorization": "Bearer nope"]))
        XCTAssertEqual(wrong, 401)
    }

    func testAForeignOriginIs403() async throws {
        try await startServer()
        let (code, _, _) = try await status(request(body: ping, headers: ["Origin": "https://evil.example"]))
        XCTAssertEqual(code, 403)
    }

    func testARebindingHostIs403() async throws {
        try await startServer()
        let client = RawHTTPClient(port: port)
        defer { client.cancel() }
        client.send(rawPing(host: "evil.example:\(port)"))
        guard case .response(let text) = await client.read() else { return XCTFail("expected a response") }
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 403"), text)
    }

    func testAnotherPathIs404() async throws {
        try await startServer()
        let (code, _, _) = try await status(request(path: "/other", body: ping))
        XCTAssertEqual(code, 404)
    }

    func testGetAndDeleteAre405() async throws {
        try await startServer()
        let (get, response, _) = try await status(request("GET"))
        XCTAssertEqual(get, 405)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Allow"), "POST")
        let (delete, _, _) = try await status(request("DELETE"))
        XCTAssertEqual(delete, 405)
    }

    func testAnUnsupportedProtocolVersionHeaderIs400() async throws {
        try await startServer()
        let (code, _, _) = try await status(request(body: ping, headers: ["MCP-Protocol-Version": "1999-01-01"]))
        XCTAssertEqual(code, 400)
    }

    func testAnOversizedBodyIs413BeforeItIsSent() async throws {
        try await startServer()
        let client = RawHTTPClient(port: port)
        defer { client.cancel() }
        client.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\n"
                    + "Content-Length: \(HTTPRequestParser.maxBodyBytes + 1)\r\n\r\n")
        guard case .response(let text) = await client.read() else { return XCTFail("expected a response") }
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 413"), text)
        let after = await client.read(timeout: 2)
        XCTAssertEqual(after, .closed, "the connection is closed after an error")
    }

    // MARK: connections

    func testKeepAliveServesSeveralRequestsOnOneConnection() async throws {
        try await startServer()
        let client = RawHTTPClient(port: port)
        defer { client.cancel() }
        for _ in 0..<3 {
            client.send(rawPing())
            guard case .response(let text) = await client.read() else { return XCTFail("expected a response") }
            XCTAssertTrue(text.hasPrefix("HTTP/1.1 200"), text)
        }
    }

    func testAnIdleOrSlowConnectionIsClosed() async throws {
        try await startServer(idleTimeout: 0.3)
        let silent = RawHTTPClient(port: port)
        defer { silent.cancel() }
        let silentOutcome = await silent.read(timeout: 3)
        XCTAssertEqual(silentOutcome, .closed)

        let slow = RawHTTPClient(port: port)
        defer { slow.cancel() }
        slow.send("POST /mcp HTTP/1.1\r\n")
        let slowOutcome = await slow.read(timeout: 3)
        XCTAssertEqual(slowOutcome, .closed, "a request that never finishes its headers is cut off")
    }

    func testConnectionsBeyondTheLimitAreClosed() async throws {
        try await startServer(maxConnections: 2)
        var clients: [RawHTTPClient] = []
        defer { clients.forEach { $0.cancel() } }
        for _ in 0..<2 {
            let client = RawHTTPClient(port: port)
            clients.append(client)
            client.send(rawPing())
            guard case .response(let text) = await client.read() else { return XCTFail("expected a response") }
            XCTAssertTrue(text.hasPrefix("HTTP/1.1 200"), text)
        }
        let extra = RawHTTPClient(port: port)
        clients.append(extra)
        extra.send(rawPing())
        let outcome = await extra.read(timeout: 3)
        XCTAssertEqual(outcome, .closed)
    }
}

/// Records the first running port reported, across the server's queue and the test.
private final class PortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt16 = 0
    var port: UInt16 { lock.withLock { value } }
    func set(_ port: UInt16) -> Bool {
        lock.withLock {
            guard value == 0 else { return false }
            value = port
            return true
        }
    }
}
