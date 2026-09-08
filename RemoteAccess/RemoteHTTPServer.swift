import Foundation
import Network

/// Small embedded HTTP/1.1 server built on Network.framework. Zero third-party
/// dependencies, matching the project's zero-dependency philosophy.
///
/// Semantics: one request per connection. Regular responses are sent with
/// `Connection: close`; SSE stream responses omit `Content-Length` and end by
/// closing the socket, which every browser handles.
///
/// The server is transport-only: routing, auth and business logic live in
/// `RemoteAccessStore` and the API services.
nonisolated final class RemoteHTTPServer {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let port: UInt16
    private let bindAllInterfaces: Bool
    private let handler: Handler
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.mlxbits.image-studio.remote")

    init(port: UInt16, bindAllInterfaces: Bool, handler: @escaping Handler) {
        self.port = port
        self.bindAllInterfaces = bindAllInterfaces
        self.handler = handler
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if !bindAllInterfaces {
            // Loopback only unless the user explicitly enabled LAN access.
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: port)!
            )
        }
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.listener = nil
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveLoop(connection, buffer: Data())
    }

    private func receiveLoop(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self, connection.state == .ready else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if buffer.count > HTTPRequestParser.maxBodyBytes + HTTPRequestParser.maxHeaderBytes {
                self.respond(connection, .jsonError(413, "request too large"))
                return
            }

            do {
                if let (request, _) = try HTTPRequestParser.parse(buffer, remoteAddress: Self.remoteDescription(connection)) {
                    Task { [handler = self.handler] in
                        let response = await handler(request)
                        self.respond(connection, response)
                    }
                    return
                }
            } catch HTTPParseError.tooLarge {
                self.respond(connection, .jsonError(413, "request too large"))
                return
            } catch {
                self.respond(connection, .jsonError(400, "malformed request"))
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receiveLoop(connection, buffer: buffer)
        }
    }

    private func respond(_ connection: NWConnection, _ response: HTTPResponse) {
        switch response.body {
        case .empty, .data:
            let body: Data
            if case .data(let data) = response.body { body = data } else { body = Data() }
            var headers = response.headers
            headers["Content-Length"] = "\(body.count)"
            headers["Connection"] = "close"
            headers["X-Content-Type-Options"] = "nosniff"
            let payload = Self.encodeHead(response.status, headers) + body
            self.write(connection, payload) {
                connection.cancel()
            }

        case .stream(let stream):
            var headers = response.headers
            headers["Connection"] = "close"
            headers["Cache-Control"] = "no-store"
            let head = Self.encodeHead(response.status, headers)
            self.write(connection, head) {
                self.pump(stream, into: connection)
            }
        }
    }

    private func pump(_ stream: AsyncStream<Data>, into connection: NWConnection) {
        Task { [weak self] in
            for await chunk in stream {
                guard connection.state == .ready else { return }
                let finished = await self?.writeAndWait(connection, chunk) ?? false
                if !finished { return }
            }
            connection.cancel()
        }
    }

    // MARK: - Low-level writes

    /// Fire-and-forget write with completion.
    private func write(_ connection: NWConnection, _ data: Data, completion: @escaping () -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in
            if error != nil { connection.cancel() }
            completion()
        })
    }

    /// Awaitable write; returns false when the connection broke.
    private func writeAndWait(_ connection: NWConnection, _ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if error != nil {
                    connection.cancel()
                    continuation.resume(returning: false)
                } else {
                    continuation.resume(returning: true)
                }
            })
        }
    }

    private static func encodeHead(_ status: Int, _ headers: [String: String]) -> Data {
        var head = HTTPStatus.line(status)
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8)
    }

    private static func remoteDescription(_ connection: NWConnection) -> String {
        if case let .hostPort(host, port) = connection.endpoint {
            return "\(host):\(port)"
        }
        return "unknown"
    }
}
