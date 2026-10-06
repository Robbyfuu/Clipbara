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

    private static let log = Logger(subsystem: "com.robbyfuu.copyd", category: "MCP")

    private let port: UInt16
    private let token: String
    private let router: MCPRouter
    private let idleTimeout: TimeInterval
    private let maxConnections: Int
    private let queue = DispatchQueue(label: "com.robbyfuu.copyd.mcp")
    /// Sent on every JSON response; sessions aren't tracked, so a client echoing it is accepted but never required.
    private let sessionID = UUID().uuidString

    private let lock = NSLock()
    private var currentState: State = .off
    private var stateHandler: (@Sendable (State) -> Void)?

    // Confined to `queue`.
    private var listener: NWListener?
    private var boundPort: UInt16 = 0
    private var clients: [ObjectIdentifier: Client] = [:]

    /// `port` 0 binds an ephemeral port, which `.running` reports.
    init(port: UInt16, token: String, router: MCPRouter, idleTimeout: TimeInterval = 30, maxConnections: Int = 8) {
        self.port = port
        self.token = token
        self.router = router
        self.idleTimeout = idleTimeout
        self.maxConnections = maxConnections
    }

    deinit {
        listener?.cancel()
        clients.values.forEach { $0.connection.cancel() }
    }

    var state: State { lock.withLock { currentState } }

    /// Called on the server's queue on every state change.
    var onStateChange: (@Sendable (State) -> Void)? {
        get { lock.withLock { stateHandler } }
        set { lock.withLock { stateHandler = newValue } }
    }

    /// Throws only for parameters Network rejects; a busy port arrives later as `.failed`.
    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: parameters)
        let id = ObjectIdentifier(listener)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, let current = self.listener, ObjectIdentifier(current) == id else { return }
            self.listenerChanged(state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, let current = self.listener, ObjectIdentifier(current) == id else { return connection.cancel() }
            self.accept(connection)
        }
        queue.async {
            self.teardown()
            self.listener = listener
            listener.start(queue: self.queue)
        }
    }

    func stop() {
        queue.async {
            self.teardown()
            self.setState(.off)
        }
    }

    // MARK: listener

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            boundPort = listener?.port?.rawValue ?? port
            Self.log.info("MCP server running on 127.0.0.1:\(self.boundPort, privacy: .public)")
            setState(.running(boundPort))
        case .failed(let error), .waiting(let error):
            let message = if case .posix(.EADDRINUSE) = error { "Port \(port) is in use" } else { error.localizedDescription }
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

    /// The timer runs from connect, or from the last response, until a whole request has arrived: a client that
    /// trickles its headers is cut off like a silent one.
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
        case .complete(let request):
            client.idleTimer?.cancel()
            serve(client, request, keepAlive: request.keepAlive && !atEnd)
        }
    }

    // MARK: requests

    private func serve(_ client: Client, _ request: HTTPRequest, keepAlive: Bool) {
        switch MCPRequestGuard.check(host: request.header("host"), origin: request.header("origin"),
                                     authorization: request.header("authorization"), port: boundPort, token: token) {
        case .forbidden:
            Self.log.notice("MCP request refused: foreign host or origin")
            return respond(client, status: 403, keepAlive: false)
        case .unauthorized:
            Self.log.notice("MCP request refused: missing or wrong token")
            return respond(client, status: 401, keepAlive: false)
        case .ok:
            break
        }
        guard request.path == "/mcp" else { return respond(client, status: 404, keepAlive: false) }
        guard request.method == "POST" else { return respond(client, status: 405, headers: [("Allow", "POST")], keepAlive: false) }
        if let version = request.header("mcp-protocol-version"), !MCPRouter.supportedVersions.contains(version) {
            return respond(client, status: 400, keepAlive: false)
        }

        let router = router
        Task {
            let response = await router.handle(request.body)
            self.queue.async {
                guard self.clients[ObjectIdentifier(client)] != nil else { return }
                switch response {
                case .json(let body):
                    self.respond(client, status: 200, headers: [("Content-Type", "application/json"), ("Mcp-Session-Id", self.sessionID)],
                                 body: body, keepAlive: keepAlive)
                case .accepted:
                    self.respond(client, status: 202, keepAlive: keepAlive)
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
