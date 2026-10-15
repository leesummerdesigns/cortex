import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String] // lowercased names
    let body: Data

    /// application/x-www-form-urlencoded body.
    var form: [String: String] { Self.decodeForm(String(data: body, encoding: .utf8) ?? "") }

    static func decodeForm(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            let decode = { (s: String) in s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s }
            if let key = parts.first { out[decode(key)] = parts.count > 1 ? decode(parts[1]) : "" }
        }
        return out
    }
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String] = [:]
    var body: Data = Data()

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"], body: data)
    }

    static func html(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store"], body: Data(text.utf8))
    }

    static func redirect(_ location: String) -> HTTPResponse {
        HTTPResponse(status: 302, headers: ["Location": location])
    }
}

/// Minimal HTTP/1.1 server bound to 127.0.0.1 (the tunnel connects locally). One request per connection.
final class HTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cortex.http")
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private static let maxBody = 4 * 1024 * 1024

    init(port: UInt16, handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
        self.handler = handler
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                FileHandle.standardError.write(Data("cortex serve: listener failed: \(error)\n".utf8))
                exit(1)
            }
        }
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                Task {
                    let response = await self.handler(request)
                    self.send(response, on: connection)
                }
            } else if isComplete || error != nil || buffer.count > Self.maxBody {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    /// Returns a request once headers and the full Content-Length body have arrived.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else { return nil }

        let target = String(requestLine[1])
        let parts = target.split(separator: "?", maxSplits: 1).map(String.init)
        return HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: parts[0],
            query: parts.count > 1 ? HTTPRequest.decodeForm(parts[1]) : [:],
            headers: headers,
            body: data.subdata(in: bodyStart..<(bodyStart + length))
        )
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func reason(_ status: Int) -> String {
        [200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 302: "Found", 400: "Bad Request",
         401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 429: "Too Many Requests",
         500: "Internal Server Error"][status] ?? "Status"
    }
}
