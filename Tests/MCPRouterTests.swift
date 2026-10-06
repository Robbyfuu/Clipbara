import XCTest

/// An in-memory `ClipLibrary` for the router and loopback tests.
actor FakeClipLibrary: ClipLibrary {
    struct Search: Equatable { let query: String?; let type: ClipKind?; let board: String?; let limit: Int }

    var summaries: [ClipSummary] = []
    var details: [UUID: ClipDetail] = [:]
    var boardList: [BoardSummary] = []
    var fails = false
    /// Thrown by `copy` only.
    var copyError: ToolError?
    private(set) var searches: [Search] = []
    private(set) var copied: [String] = []

    struct Failure: Error {}

    func configure(summaries: [ClipSummary] = [], details: [ClipDetail] = [], boards: [BoardSummary] = [], fails: Bool = false,
                   copyError: ToolError? = nil) {
        self.summaries = summaries
        self.details = Dictionary(uniqueKeysWithValues: details.map { ($0.id, $0) })
        self.boardList = boards
        self.fails = fails
        self.copyError = copyError
    }

    func search(query: String?, type: ClipKind?, board: String?, limit: Int) async throws -> [ClipSummary] {
        if fails { throw Failure() }
        searches.append(Search(query: query, type: type, board: board, limit: limit))
        return Array(summaries.prefix(limit))
    }

    func clip(id: UUID) async throws -> ClipDetail? {
        if fails { throw Failure() }
        return details[id]
    }

    func boards() async throws -> [BoardSummary] {
        if fails { throw Failure() }
        return boardList
    }

    func copy(text: String) async throws {
        if fails { throw Failure() }
        if let copyError { throw copyError }
        copied.append(text)
    }
}

/// A thread-safe uptime the tests move forward.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// A thread-safe switch the tests flip between requests.
final class WriteSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    var isOn: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// JSON-RPC in, JSON-RPC out (spec §2 methods, §3 tools), against the MCP 2025-06-18 shapes.
final class MCPRouterTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)
    private let clipID = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!

    private func router(_ library: FakeClipLibrary, write: Bool = false) -> MCPRouter {
        MCPRouter(library: library, allowsWrite: { write })
    }

    private func send(_ json: String, to router: MCPRouter) async -> [String: Any] {
        guard case .json(let data) = await router.handle(Data(json.utf8)) else {
            XCTFail("expected a JSON body for \(json)")
            return [:]
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func call(_ tool: String, _ arguments: String = "{}", library: FakeClipLibrary, write: Bool = false) async -> [String: Any] {
        await send(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#,
                   to: router(library, write: write))
    }

    private func errorCode(_ response: [String: Any]) -> Int? {
        (response["error"] as? [String: Any])?["code"] as? Int
    }

    private func toolResult(_ response: [String: Any]) -> [String: Any] {
        response["result"] as? [String: Any] ?? [:]
    }

    // MARK: initialize and ping

    func testInitializeAnswersTheSupportedVersionWithToolsAndServerInfo() async {
        let response = await send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#,
                                  to: router(FakeClipLibrary()))
        XCTAssertEqual(response["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(response["id"] as? Int, 1)
        let result = toolResult(response)
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"] as? [String: Any])
        let info = result["serverInfo"] as? [String: Any]
        XCTAssertEqual(info?["name"] as? String, "copyd")
        XCTAssertNotNil(info?["version"] as? String)
    }

    func testInitializeEchoesAStringId() async {
        let response = await send(#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
                                  to: router(FakeClipLibrary()))
        XCTAssertEqual(response["id"] as? String, "a", "string ids are echoed")
    }

    func testInitializeAnswersItsOwnVersionForAnUnknownOne() async {
        for version in [#""2025-03-26""#, #""2099-01-01""#, #""""#, "7"] {
            let response = await send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":\#(version)}}"#,
                                      to: router(FakeClipLibrary()))
            XCTAssertEqual(toolResult(response)["protocolVersion"] as? String, "2025-06-18", version)
        }
    }

    func testPingAnswersAnEmptyResult() async {
        let response = await send(#"{"jsonrpc":"2.0","id":"123","method":"ping"}"#, to: router(FakeClipLibrary()))
        XCTAssertEqual(response["id"] as? String, "123")
        XCTAssertEqual(response["result"] as? [String: Int], [:])
    }

    // MARK: notifications

    func testNotificationsAreAcceptedWithoutABody() async {
        let r = router(FakeClipLibrary())
        let initialized = await r.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        XCTAssertEqual(initialized, .accepted)
        let unknown = await r.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/whatever","params":{}}"#.utf8))
        XCTAssertEqual(unknown, .accepted, "a notification never gets a response, even an unknown one")
        let clientResponse = await r.handle(Data(#"{"jsonrpc":"2.0","id":4,"result":{}}"#.utf8))
        XCTAssertEqual(clientResponse, .accepted, "a JSON-RPC response from the client is accepted")
    }

    // MARK: tools/list

    private func toolNames(write: Bool) async -> [String] {
        let response = await send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, to: router(FakeClipLibrary(), write: write))
        return (toolResult(response)["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    func testToolsListHidesCopyWhileWritingIsOff() async {
        let names = await toolNames(write: false)
        XCTAssertEqual(names, ["search_clips", "get_clip", "list_pinboards"])
    }

    func testToolsListShowsCopyWhenWritingIsOn() async {
        let names = await toolNames(write: true)
        XCTAssertEqual(names, ["search_clips", "get_clip", "list_pinboards", "copy_to_clipboard"])
    }

    func testEveryToolDeclaresADescriptionAndObjectSchemas() async {
        let response = await send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, to: router(FakeClipLibrary(), write: true))
        let tools = toolResult(response)["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.count, 4)
        for tool in tools {
            let name = tool["name"] as? String ?? "?"
            XCTAssertFalse((tool["description"] as? String ?? "").isEmpty, name)
            XCTAssertEqual((tool["inputSchema"] as? [String: Any])?["type"] as? String, "object", name)
            XCTAssertEqual((tool["outputSchema"] as? [String: Any])?["type"] as? String, "object", name)
        }
        let search = tools.first { $0["name"] as? String == "search_clips" }
        let props = (search?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
        let type = props?["type"] as? [String: Any]
        XCTAssertEqual(type?["enum"] as? [String], ["text", "link", "image", "file", "color", "code"])
        let get = tools.first { $0["name"] as? String == "get_clip" }
        XCTAssertEqual((get?["inputSchema"] as? [String: Any])?["required"] as? [String], ["id"])
    }


    func testTheWriteSwitchIsReadOnEveryRequest() async {
        let toggle = WriteSwitch(false)
        let library = FakeClipLibrary()
        let r = MCPRouter(library: library, allowsWrite: { toggle.isOn })
        let copy = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"copy_to_clipboard","arguments":{"text":"hi"}}}"#
        let refused = await send(copy, to: r)
        XCTAssertEqual(errorCode(refused), -32602)
        toggle.isOn = true
        let allowed = await send(copy, to: r)
        XCTAssertEqual(toolResult(allowed)["isError"] as? Bool, false)
        let copied = await library.copied
        XCTAssertEqual(copied, ["hi"])
    }

    // MARK: tools/call search_clips

    func testSearchPassesItsArgumentsAndReturnsTextAndStructuredContent() async throws {
        let library = FakeClipLibrary()
        await library.configure(summaries: [ClipSummary(id: clipID, type: .link, preview: "apple.com", app: "Safari", copiedAt: date, pinned: true)])
        let response = await call("search_clips", #"{"query":"apple","type":"link","board":"links","limit":5}"#, library: library)
        let searches = await library.searches
        XCTAssertEqual(searches, [.init(query: "apple", type: .link, board: "links", limit: 5)])

        let result = toolResult(response)
        XCTAssertEqual(result["isError"] as? Bool, false)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let clip = try XCTUnwrap((structured["clips"] as? [[String: Any]])?.first)
        XCTAssertEqual(clip["id"] as? String, clipID.uuidString)
        XCTAssertEqual(clip["type"] as? String, "link")
        XCTAssertEqual(clip["preview"] as? String, "apple.com")
        XCTAssertEqual(clip["app"] as? String, "Safari")
        XCTAssertEqual(clip["copied_at"] as? String, ISO8601DateFormatter().string(from: date))
        XCTAssertEqual(clip["pinned"] as? Bool, true)

        let content = try XCTUnwrap((result["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(content["type"] as? String, "text")
        let text = try XCTUnwrap(content["text"] as? String)
        let fromText = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
        XCTAssertEqual(fromText, structured as NSDictionary, "the text block carries the same object")
    }

    func testSearchDefaultsAndClampsTheLimit() async {
        let library = FakeClipLibrary()
        _ = await call("search_clips", "{}", library: library)
        _ = await call("search_clips", #"{"limit":500}"#, library: library)
        _ = await call("search_clips", #"{"limit":0}"#, library: library)
        let limits = await library.searches.map(\.limit)
        XCTAssertEqual(limits, [20, 50, 1])
        let empty = await library.searches.first
        XCTAssertEqual(empty, .init(query: nil, type: nil, board: nil, limit: 20))
    }

    func testSearchTreatsABlankQueryAsNone() async {
        let library = FakeClipLibrary()
        _ = await call("search_clips", #"{"query":"   ","board":""}"#, library: library)
        let search = await library.searches.first
        XCTAssertEqual(search, .init(query: nil, type: nil, board: nil, limit: 20))
    }

    func testSearchRejectsInvalidArguments() async {
        for arguments in [#"{"type":"video"}"#, #"{"limit":"ten"}"#, #"{"limit":2.5}"#, #"{"limit":true}"#, #"{"query":5}"#,
                          #"{"board":["a"]}"#] {
            let response = await call("search_clips", arguments, library: FakeClipLibrary())
            XCTAssertEqual(errorCode(response), -32602, arguments)
        }
    }

    func testALibraryFailureIsAToolError() async {
        let library = FakeClipLibrary()
        await library.configure(fails: true)
        let result = toolResult(await call("search_clips", library: library))
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertNotNil((result["content"] as? [[String: Any]])?.first?["text"] as? String)
    }

    // MARK: tools/call get_clip

    func testGetClipReturnsTheDetailInSnakeCase() async throws {
        let library = FakeClipLibrary()
        await library.configure(details: [ClipDetail(id: clipID, type: .image, text: nil, truncated: false, app: "Preview", copiedAt: date,
                                                     linkTitle: nil, ocrText: "Receipt 42", fileNames: [])])
        let response = await call("get_clip", #"{"id":"\#(clipID.uuidString.lowercased())"}"#, library: library)
        let structured = try XCTUnwrap(toolResult(response)["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["id"] as? String, clipID.uuidString)
        XCTAssertEqual(structured["type"] as? String, "image")
        XCTAssertEqual(structured["ocr_text"] as? String, "Receipt 42")
        XCTAssertEqual(structured["copied_at"] as? String, ISO8601DateFormatter().string(from: date))
        XCTAssertEqual(structured["truncated"] as? Bool, false)
        XCTAssertNil(structured["text"], "an image has no text and never pixels")
    }

    func testGetClipOfAnUnknownOrMalformedIdIsNotFound() async {
        for id in [UUID().uuidString, "not-a-uuid"] {
            let result = toolResult(await call("get_clip", #"{"id":"\#(id)"}"#, library: FakeClipLibrary()))
            XCTAssertEqual(result["isError"] as? Bool, true, id)
            XCTAssertEqual((result["content"] as? [[String: Any]])?.first?["text"] as? String, "Clip not found", id)
            XCTAssertNil(result["structuredContent"], id)
        }
    }

    func testGetClipWithoutAnIdIsInvalid() async {
        let missing = await call("get_clip", "{}", library: FakeClipLibrary())
        XCTAssertEqual(errorCode(missing), -32602)
        let number = await call("get_clip", #"{"id":3}"#, library: FakeClipLibrary())
        XCTAssertEqual(errorCode(number), -32602)
    }

    // MARK: tools/call list_pinboards

    func testListPinboardsSplitsUserAndSmartBoards() async throws {
        let library = FakeClipLibrary()
        await library.configure(boards: [BoardSummary(id: nil, name: "Recipes", count: 3), BoardSummary(id: "links", name: "Links", count: 7)])
        let response = await call("list_pinboards", library: library)
        let structured = try XCTUnwrap(toolResult(response)["structuredContent"] as? [String: Any])
        let pinboards = try XCTUnwrap(structured["pinboards"] as? [[String: Any]])
        XCTAssertEqual(pinboards.count, 1)
        XCTAssertEqual(pinboards.first?["name"] as? String, "Recipes")
        XCTAssertEqual(pinboards.first?["count"] as? Int, 3)
        XCTAssertNil(pinboards.first?["id"])
        let smart = try XCTUnwrap(structured["smart_boards"] as? [[String: Any]])
        XCTAssertEqual(smart.first?["id"] as? String, "links")
        XCTAssertEqual(smart.first?["count"] as? Int, 7)
    }

    // MARK: tools/call copy_to_clipboard

    func testCopyWritesTheTextWhenAllowed() async {
        let library = FakeClipLibrary()
        let result = toolResult(await call("copy_to_clipboard", #"{"text":"héllo"}"#, library: library, write: true))
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual((result["structuredContent"] as? [String: Any])?["copied"] as? Bool, true)
        let copied = await library.copied
        XCTAssertEqual(copied, ["héllo"])
    }

    /// A runaway client can't flood the clipboard, nor the history behind it.
    func testCopiesAreLimitedToOnePerSecond() async {
        let clock = TestClock()
        let library = FakeClipLibrary()
        let r = MCPRouter(library: library, allowsWrite: { true }, now: { clock.now })
        let copy = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"copy_to_clipboard","arguments":{"text":"hi"}}}"#

        let first = toolResult(await send(copy, to: r))
        XCTAssertEqual(first["isError"] as? Bool, false)
        clock.now = 0.999
        let second = toolResult(await send(copy, to: r))
        XCTAssertEqual(second["isError"] as? Bool, true)
        XCTAssertEqual((second["content"] as? [[String: Any]])?.first?["text"] as? String, "Too many copies; try again in a moment.")
        clock.now = 1
        let third = toolResult(await send(copy, to: r))
        XCTAssertEqual(third["isError"] as? Bool, false)

        let copied = await library.copied
        XCTAssertEqual(copied, ["hi", "hi"])
    }

    /// One copy a second still adds up: at most 20 in any 10 minutes, so a client can't push the history out.
    func testCopiesAreLimitedTo20PerRolling10Minutes() async {
        let clock = TestClock()
        let library = FakeClipLibrary()
        let r = MCPRouter(library: library, allowsWrite: { true }, now: { clock.now })
        let copy = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"copy_to_clipboard","arguments":{"text":"hi"}}}"#
        func message(at time: TimeInterval) async -> String? {
            clock.now = time
            let result = toolResult(await send(copy, to: r))
            return result["isError"] as? Bool == true ? (result["content"] as? [[String: Any]])?.first?["text"] as? String : nil
        }

        for second in 0..<20 {
            let refusal = await message(at: TimeInterval(second))
            XCTAssertNil(refusal, "copy \(second + 1) is within the budget")
        }
        let twentyFirst = await message(at: 20)
        XCTAssertEqual(twentyFirst, "Too many copies; try again in a moment.")
        let justBefore = await message(at: 599.999)
        XCTAssertEqual(justBefore, "Too many copies; try again in a moment.", "the first copy still counts")
        let once10MinutesPass = await message(at: 600)
        XCTAssertNil(once10MinutesPass, "the first copy has left the window")
        let next = await message(at: 601)
        XCTAssertNil(next, "rolling: the second copy has left too")

        let copied = await library.copied
        XCTAssertEqual(copied.count, 22)
    }

    /// The library's own refusal reaches the client word for word.
    func testAToolErrorFromTheLibraryIsShownAsIs() async {
        let library = FakeClipLibrary()
        await library.configure(copyError: .pasting)
        let result = toolResult(await call("copy_to_clipboard", #"{"text":"hi"}"#, library: library, write: true))
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual((result["content"] as? [[String: Any]])?.first?["text"] as? String,
                       "Copyd is pasting right now; try again in a moment.")
    }

    /// An agent's copy landing between Copyd's own clipboard write and its ⌘V would be pasted instead of the user's pick.
    func testWritesWaitWhileCopydIsPasting() {
        XCTAssertNil(ToolError.busy(pasteStackActive: false, autoPastePending: false))
        XCTAssertEqual(ToolError.busy(pasteStackActive: true, autoPastePending: false), .pasting)
        XCTAssertEqual(ToolError.busy(pasteStackActive: false, autoPastePending: true), .pasting)
        XCTAssertEqual(ToolError.busy(pasteStackActive: true, autoPastePending: true), .pasting)
        XCTAssertEqual(ToolError.pasting.message, "Copyd is pasting right now; try again in a moment.")
    }

    func testCopyIsAnUnknownToolWhileWritingIsOff() async {
        let library = FakeClipLibrary()
        let response = await call("copy_to_clipboard", #"{"text":"x"}"#, library: library, write: false)
        XCTAssertEqual(errorCode(response), -32602)
        let copied = await library.copied
        XCTAssertEqual(copied, [], "nothing reaches the clipboard")
    }

    func testCopyRejectsMissingOrOversizedText() async {
        let library = FakeClipLibrary()
        let limit = MCPTools.maxCopyBytes
        let atLimit = String(repeating: "a", count: limit)
        let fits = await call("copy_to_clipboard", #"{"text":"\#(atLimit)"}"#, library: library, write: true)
        XCTAssertEqual(toolResult(fits)["isError"] as? Bool, false)
        let tooLong = await call("copy_to_clipboard", #"{"text":"\#(atLimit)a"}"#, library: library, write: true)
        XCTAssertEqual(errorCode(tooLong), -32602)
        let missing = await call("copy_to_clipboard", "{}", library: library, write: true)
        XCTAssertEqual(errorCode(missing), -32602)
        let copied = await library.copied.count
        XCTAssertEqual(copied, 1)
    }

    // MARK: errors

    func testAnUnknownToolIsInvalidParams() async {
        let response = await call("delete_everything", library: FakeClipLibrary())
        XCTAssertEqual(errorCode(response), -32602)
    }

    func testToolsCallWithoutANameIsInvalidParams() async {
        let response = await send(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{}}"#, to: router(FakeClipLibrary()))
        XCTAssertEqual(errorCode(response), -32602)
        let badArgs = await send(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"search_clips","arguments":[1]}}"#,
                                 to: router(FakeClipLibrary()))
        XCTAssertEqual(errorCode(badArgs), -32602)
    }

    func testAnUnknownMethodIsMethodNotFound() async {
        let response = await send(#"{"jsonrpc":"2.0","id":6,"method":"resources/list"}"#, to: router(FakeClipLibrary()))
        XCTAssertEqual(errorCode(response), -32601)
        XCTAssertEqual(response["id"] as? Int, 6)
    }

    /// The HTTP status the server sends for a router answer, and its JSON body.
    private func reply(_ body: String, to router: MCPRouter) async -> (status: Int, body: [String: Any]) {
        switch await router.handle(Data(body.utf8)) {
        case .accepted: return (202, [:])
        case .json(let data): return (200, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        case .invalid(let data): return (400, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        }
    }

    func testInvalidJSONIsAParseErrorSentAs400() async {
        for body in ["{", "", "not json", #"{"jsonrpc":"2.0","id":1,"method":"ping""#] {
            let (status, response) = await reply(body, to: router(FakeClipLibrary()))
            XCTAssertEqual(status, 400, body)
            XCTAssertEqual(errorCode(response), -32700, body)
            XCTAssertTrue(response["id"] is NSNull, "a parse error answers with a null id")
        }
    }

    func testAMessageWithoutAReadableIdIsAnInvalidRequestSentAs400() async {
        for body in [#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#, #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#,
                     #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#, #"{"jsonrpc":"2.0","id":1.5,"method":"ping"}"#,
                     #"{"jsonrpc":"2.0","id":{},"method":"ping"}"#, #"{"jsonrpc":"2.0","method":7}"#, "42", #""ping""#] {
            let (status, response) = await reply(body, to: router(FakeClipLibrary()))
            XCTAssertEqual(status, 400, body)
            XCTAssertEqual(errorCode(response), -32600, body)
            XCTAssertTrue(response["id"] is NSNull, body)
        }
    }

    func testAMessageWithAReadableIdIsAnInvalidRequestForThatId() async {
        for body in [#"{"id":1,"method":"ping"}"#, #"{"jsonrpc":"1.0","id":1,"method":"ping"}"#,
                     #"{"jsonrpc":"2.0","id":1,"method":7}"#, #"{"jsonrpc":"2.0","id":1}"#] {
            let (status, response) = await reply(body, to: router(FakeClipLibrary()))
            XCTAssertEqual(status, 200, body)
            XCTAssertEqual(errorCode(response), -32600, body)
            XCTAssertEqual(response["id"] as? Int, 1, body)
        }
    }

    /// An id that isn't an exact integer would be echoed into the response, and writing an infinite number raises.
    func testAnInfiniteOrHugeIdNeverCrashes() async {
        for id in ["1e309", "-1e309", "1e300"] {
            let (status, response) = await reply(#"{"jsonrpc":"2.0","id":\#(id),"method":"ping"}"#, to: router(FakeClipLibrary()))
            XCTAssertEqual(status, 400, id)
            XCTAssertTrue([-32600, -32700].contains(errorCode(response) ?? 0), id)
        }
    }

    func testAMegabyteOfOpenBracketsIsAParseError() async {
        let (status, response) = await reply(String(repeating: "[", count: 1_048_576), to: router(FakeClipLibrary()))
        XCTAssertEqual(status, 400)
        XCTAssertEqual(errorCode(response), -32700)
    }
}
