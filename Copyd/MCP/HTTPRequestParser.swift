import Foundation

/// One parsed HTTP/1.1 request. Header names are lowercased.
struct HTTPRequest: Equatable, Sendable {
    let method: String
    /// The request target without its query.
    let path: String
    let version: String
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// HTTP/1.1 keeps the connection open unless the client sends `Connection: close`.
    var keepAlive: Bool {
        version == "HTTP/1.1"
            && !(header("connection") ?? "").lowercased().split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "close" }
    }
}

/// Incremental HTTP/1.1 request parser for the MCP server. Bounded: a header block over 16 KB is 431, a body over
/// 1 MB is 413 before any of it is read, a POST needs `Content-Length` (411) and chunked bodies are refused (411).
/// After a `.failure` the connection must be closed.
struct HTTPRequestParser {
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 1024 * 1024

    enum Outcome: Equatable {
        case incomplete
        case complete(HTTPRequest)
        /// The HTTP status to answer with before closing.
        case failure(Int)
    }

    private struct Head {
        let method: String
        let path: String
        let version: String
        let headers: [String: String]
        let length: Int
    }

    private static let terminator = Data("\r\n\r\n".utf8)
    /// Headers whose repetition is ambiguous, so a smuggling or rebinding attempt.
    private static let singleHeaders: Set<String> = ["host", "content-length", "authorization", "origin", "transfer-encoding"]

    private var buffer = Data()
    private var head: Head?

    /// Appends `data` and returns the next request once whole. Bytes past it stay for the next call (pipelining).
    mutating func feed(_ data: Data) -> Outcome {
        buffer.append(data)
        if head == nil {
            guard let end = buffer.range(of: Self.terminator) else {
                return buffer.count > Self.maxHeaderBytes ? .failure(431) : .incomplete
            }
            guard end.lowerBound - buffer.startIndex <= Self.maxHeaderBytes else { return .failure(431) }
            switch Self.parseHead(buffer[buffer.startIndex..<end.lowerBound]) {
            case .success(let parsed): head = parsed
            case .failure(let status): return .failure(status.code)
            }
            buffer = Data(buffer[end.upperBound...])
        }
        guard let head, buffer.count >= head.length else { return .incomplete }
        let body = Data(buffer.prefix(head.length))
        buffer = Data(buffer.dropFirst(head.length))
        self.head = nil
        return .complete(HTTPRequest(method: head.method, path: head.path, version: head.version, headers: head.headers, body: body))
    }

    private struct Status: Error { let code: Int }

    private static func parseHead(_ bytes: Data) -> Result<Head, Status> {
        guard let text = String(data: bytes, encoding: .utf8) else { return .failure(Status(code: 400)) }
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              !parts[0].isEmpty, parts[0].allSatisfy({ $0.isASCII && $0.isUppercase }),
              parts[1].hasPrefix("/"),
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0"
        else { return .failure(Status(code: 400)) }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .failure(Status(code: 400)) }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, !name.contains(where: { $0 == " " || $0 == "\t" }) else { return .failure(Status(code: 400)) }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            if let existing = headers[name] {
                guard !singleHeaders.contains(name) else { return .failure(Status(code: 400)) }
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        if headers["transfer-encoding"] != nil { return .failure(Status(code: 411)) }
        var length = 0
        if let value = headers["content-length"] {
            guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) else { return .failure(Status(code: 400)) }
            guard let parsed = Int(value), parsed <= maxBodyBytes else { return .failure(Status(code: 413)) }
            length = parsed
        } else if parts[0] == "POST" {
            return .failure(Status(code: 411))
        }
        let path = String(parts[1].prefix { $0 != "?" })
        return .success(Head(method: parts[0], path: path, version: parts[2], headers: headers, length: length))
    }
}
