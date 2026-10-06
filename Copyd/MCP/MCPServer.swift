import Foundation
import Network
import os

/// The local MCP server: Streamable HTTP with JSON responses only, bound to 127.0.0.1 (spec §2).
///
/// All socket I/O and connection state live on `queue`. Only the router's async work leaves it, and its answer hops
/// back before anything is sent. `start` and `stop` only enqueue work, so any thread may call them.
final class MCPServer: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case off
        case running(UInt16)
        /// Shown in Settings, e.g. "Port 39787 is in use".
        case failed(String)
    }

    // Settings > Integrations, in `.standard`.
    static let enabledDefaultsKey = "mcpServerEnabled"
    static let portDefaultsKey = "mcpServerPort"
    static let allowsWriteDefaultsKey = "mcpAllowsWrite"
    static let defaultPort = 39787
    static let ports = 1024...65535

    /// The saved port, or the default when it is outside `ports`.
    static var savedPort: Int {
        let port = UserDefaults.standard.object(forKey: portDefaultsKey) as? Int ?? defaultPort
        return ports.contains(port) ? port : defaultPort
    }

    /// The `.failed` message for a busy port, which Settings shows localized.
    static func portInUse(_ port: UInt16) -> String { "Port \(port) is in use" }

    private static let log = Logger(subsystem: "com.robbyfuu.copyd", category: "MCP")

    private let port: UInt16
    private var currentToken: String
    private let router: MCPRouter
    private let idleTimeout: TimeInterval
    private let maxConnections: Int
    private let queue = DispatchQueue(label: "com.robbyfuu.copyd.mcp")
    /// Sent on every JSON response; sessions aren't tracked, so a client echoing it is accepted but never required.
    private let sessionID = UUID().uuidString

    private let lock = NSLock()
    private var currentState: State = .off
    private var stateHandler: (@Sendable (State) -> Void)?

    /// A busy port is tried again this many times, `bindRetryDelay` apart, before it fails: a server just stopped on
    /// the same port (a restart from Settings) may still be closing its listener.
    private static let bindRetries = 5
    private static let bindRetryDelay: TimeInterval = 0.1

    // Confined to `queue`.
    private var listener: NWListener?
    private var retriesLeft = 0
    private var retry: DispatchWorkItem?
    private var boundPort: UInt16 = 0
    private var clients: [ObjectIdentifier: Client] = [:]

    /// `port` 0 binds an ephemeral port, which `.running` reports.
    init(port: UInt16, token: String, router: MCPRouter, idleTimeout: TimeInterval = 30, maxConnections: Int = 8) {
        self.port = port
        self.currentToken = token
        self.router = router
        self.idleTimeout = idleTimeout
        self.maxConnections = maxConnections
    }

    deinit {
        listener?.cancel()
        clients.values.forEach { $0.connection.cancel() }
    }

    var state: State { lock.withLock { currentState } }

    /// Read on every request, so Regenerate applies without rebinding the port.
    var token: String {
        get { lock.withLock { currentToken } }
        set { lock.withLock { currentToken = newValue } }
    }

    /// Called on the server's queue on every state change.
    var onStateChange: (@Sendable (State) -> Void)? {
        get { lock.withLock { stateHandler } }
        set { lock.withLock { stateHandler = newValue } }
    }

    /// Throws only for parameters Network rejects; a busy port arrives later as `.failed`.
    func start() throws {
        let listener = try makeListener()
        queue.async {
            self.teardown()
            self.retriesLeft = Self.bindRetries
            self.listen(listener)
        }
    }

    func stop() {
        queue.async {
            self.teardown()
            self.setState(.off)
        }
    }

    // MARK: listener

    private func makeListener() throws -> NWListener {
        let parameters = NWParameters.tcp
        // Lets a restart bind past connections in TIME_WAIT. A port another listener holds still fails as in use.
        parameters.allowLocalEndpointReuse = true
        // Defense in depth on top of the loopback-only endpoint.
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        return try NWListener(using: parameters)
    }

    /// On `queue`.
    private func listen(_ listener: NWListener) {
        let id = ObjectIdentifier(listener)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, let current = self.listener, ObjectIdentifier(current) == id else { return }
            self.listenerChanged(state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, let current = self.listener, ObjectIdentifier(current) == id else { return connection.cancel() }
            self.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            boundPort = listener?.port?.rawValue ?? port
            Self.log.info("MCP server running on 127.0.0.1:\(self.boundPort, privacy: .public)")
            setState(.running(boundPort))
        case .failed(let error), .waiting(let error):
            if case .posix(.EADDRINUSE) = error, retriesLeft > 0 {
                retriesLeft -= 1
                teardown()
                let retry = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    do { self.listen(try self.makeListener()) } catch { self.setState(.failed(error.localizedDescription)) }
                }
                self.retry = retry
                queue.asyncAfter(deadline: .now() + Self.bindRetryDelay, execute: retry)
                return
            }
            let message = if case .posix(.EADDRINUSE) = error { Self.portInUse(port) } else { error.localizedDescription }
            Self.log.error("MCP server failed: \(message, privacy: .public)")
            teardown()
            setState(.failed(message))
        default:
            break
        }
    }

    private func setState(_ state: State) {
        let handler = lock.withLock {
            currentState = state
            return stateHandler
        }
        handler?(state)
    }

    private func teardown() {
        retry?.cancel()
        retry = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        clients.values.forEach(drop)
    }

    // MARK: connections

    /// One connection and its parser. Confined to the server's queue.
    private final class Client: @unchecked Sendable {
        let connection: NWConnection
        var parser = HTTPRequestParser()
        var idleTimer: DispatchWorkItem?
        /// The request the router is working on; dropping the client cancels it.
        var request: Task<Void, Never>?
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private func accept(_ connection: NWConnection) {
        guard clients.count < maxConnections else { return connection.cancel() }
        let client = Client(connection)
        clients[ObjectIdentifier(client)] = client
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.drop(client)
            default: break
            }
        }
        connection.start(queue: queue)
        armIdleTimer(client)
        receive(client)
    }

    /// The timer runs from connect, or from the last response, until a whole request has arrived, and again from then
    /// until its response is sent: a client that trickles its headers, or never reads its answer, is cut off like a
    /// silent one, and so is a request the library never finishes.
    private func armIdleTimer(_ client: Client) {
        client.idleTimer?.cancel()
        let timer = DispatchWorkItem { [weak self, weak client] in
            guard let self, let client else { return }
            self.drop(client)
        }
        client.idleTimer = timer
        queue.asyncAfter(deadline: .now() + idleTimeout, execute: timer)
    }

    private func drop(_ client: Client) {
        client.idleTimer?.cancel()
        client.request?.cancel()
        client.connection.stateUpdateHandler = nil
        client.connection.cancel()
        clients[ObjectIdentifier(client)] = nil
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            self?.pump(client, data ?? Data(), atEnd: isComplete || error != nil)
        }
    }

    private func pump(_ client: Client, _ data: Data, atEnd: Bool) {
        guard clients[ObjectIdentifier(client)] != nil else { return }
        switch client.parser.feed(data) {
        case .incomplete:
            atEnd ? drop(client) : receive(client)
        case .failure(let status):
            respond(client, status: status, keepAlive: false)
        case .head(let head):
            if let refusal = refusal(for: head) {
                return respond(client, status: refusal.status, headers: refusal.headers, keepAlive: false)
            }
            pump(client, Data(), atEnd: atEnd)
        case .complete(let request):
            armIdleTimer(client)
            serve(client, request, keepAlive: request.keepAlive && !atEnd)
        }
    }

    // MARK: requests

    /// The checks that need only the headers, run before any body is buffered. `nil` lets the request through.
    private func refusal(for head: HTTPRequest) -> (status: Int, headers: [(String, String)])? {
        switch MCPRequestGuard.check(host: head.header("host"), origin: head.header("origin"),
                                     authorization: head.header("authorization"), port: boundPort, token: token) {
        case .forbidden:
            Self.log.notice("MCP request refused: foreign host or origin")
            return (403, [])
        case .unauthorized:
            Self.log.notice("MCP request refused: missing or wrong token")
            return (401, [])
        case .ok:
            break
        }
        if head.path != "/mcp" { return (404, []) }
        if head.method != "POST" { return (405, [("Allow", "POST")]) }
        if let version = head.header("mcp-protocol-version"), !MCPRouter.supportedVersions.contains(version) { return (400, []) }
        return nil
    }

    private func serve(_ client: Client, _ request: HTTPRequest, keepAlive: Bool) {
        let router = router
        client.request = Task {
            let response = await router.handle(request.body)
            self.queue.async {
                guard self.clients[ObjectIdentifier(client)] != nil else { return }
                switch response {
                case .json(let body):
                    self.respond(client, status: 200, headers: [("Content-Type", "application/json"), ("Mcp-Session-Id", self.sessionID)],
                                 body: body, keepAlive: keepAlive)
                case .accepted:
                    self.respond(client, status: 202, keepAlive: keepAlive)
                case .invalid(let body):
                    self.respond(client, status: 400, headers: [("Content-Type", "application/json")], body: body, keepAlive: keepAlive)
                }
            }
        }
    }

    private func respond(_ client: Client, status: Int, headers: [(String, String)] = [], body: Data = Data(), keepAlive: Bool) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        var message = Data(head.utf8)
        message.append(body)
        client.connection.send(content: message, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            guard keepAlive, error == nil else { return self.drop(client) }
            self.armIdleTimer(client)
            self.pump(client, Data(), atEnd: false)
        })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 431: "Request Header Fields Too Large"
        default: "Error"
        }
    }
}
