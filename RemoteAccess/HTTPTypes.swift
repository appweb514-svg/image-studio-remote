import Foundation

// Minimal HTTP primitives for the embedded remote-access server. The server
// speaks HTTP/1.1 with `Connection: close` semantics (one request per
// connection), which every browser and HTTP client handles correctly and which
// keeps the implementation small and audit-friendly.

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data
    var remoteAddress: String

    var isKeepAlive: Bool { false }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    var cookies: [String: String] {
        guard let raw = header("cookie") else { return [:] }
        var out: [String: String] = [:]
        for part in raw.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            out[kv[0].trimmingCharacters(in: .whitespaces)] = String(kv[1])
        }
        return out
    }
}

enum HTTPResponseBody {
    case empty
    case data(Data)
    case stream(AsyncStream<Data>)
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: HTTPResponseBody

    static func json(_ value: some Encodable, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: .data(data)
        )
    }

    static func jsonError(_ status: Int, _ message: String) -> HTTPResponse {
        struct Err: Encodable { let error: String }
        return json(Err(error: message), status: status)
    }

    static func html(_ string: String) -> HTTPResponse {
        HTTPResponse(
            status: 200,
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: .data(Data(string.utf8))
        )
    }

    static func data(_ data: Data, contentType: String, cacheSeconds: Int = 0) -> HTTPResponse {
        var headers = ["Content-Type": contentType]
        if cacheSeconds > 0 {
            headers["Cache-Control"] = "private, max-age=\(cacheSeconds)"
        }
        return HTTPResponse(status: 200, headers: headers, body: .data(data))
    }

    static func fileNotFound() -> HTTPResponse {
        jsonError(404, "not found")
    }

    static func unauthorized() -> HTTPResponse {
        HTTPResponse(
            status: 401,
            headers: ["WWW-Authenticate": "Bearer"],
            body: .data(Data(#"{"error":"unauthorized"}"#.utf8))
        )
    }

    static func tooManyRequests() -> HTTPResponse {
        jsonError(429, "too many attempts, try again later")
    }

    init(status: Int, headers: [String: String], body: HTTPResponseBody) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

enum HTTPStatus {
    static let phrases: [Int: String] = [
        200: "OK", 201: "Created", 202: "Accepted", 204: "No Content",
        400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
        404: "Not Found", 405: "Method Not Allowed", 409: "Conflict",
        413: "Payload Too Large", 415: "Unsupported Media Type",
        422: "Unprocessable Entity", 429: "Too Many Requests",
        500: "Internal Server Error", 503: "Service Unavailable",
    ]

    static func line(_ code: Int) -> String {
        "HTTP/1.1 \(code) \(phrases[code] ?? "OK")\r\n"
    }
}

// Request parsing errors surface as 400s.
enum HTTPParseError: Error {
    case malformed
    case tooLarge
}

enum HTTPRequestParser {
    /// Maximum accepted body. Uploads (img2img from a phone) must fit.
    static let maxBodyBytes = 32 * 1024 * 1024
    static let maxHeaderBytes = 32 * 1024

    /// Parses a complete request from `buffer`. Returns nil when more bytes are
    /// needed, throws when the request is malformed or over the limits.
    static func parse(_ buffer: Data, remoteAddress: String) throws -> (request: HTTPRequest, consumed: Int)? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > maxHeaderBytes { throw HTTPParseError.tooLarge }
            return nil
        }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw HTTPParseError.malformed
        }
        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw HTTPParseError.malformed }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ")
        guard parts.count == 3 else { throw HTTPParseError.malformed }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        guard let contentLengthHeader = headers["content-length"] else {
            throw HTTPParseError.malformed
        }
        guard let contentLength = Int(contentLengthHeader), contentLength >= 0 else {
            throw HTTPParseError.malformed
        }
        guard contentLength <= maxBodyBytes else { throw HTTPParseError.tooLarge }

        let bodyStart = headerEnd.upperBound
        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength, limitedBy: buffer.endIndex)
        guard let bodyEnd, buffer.distance(from: bodyStart, to: bodyEnd) == contentLength else {
            return nil // need more bytes
        }
        let body = buffer.subdata(in: bodyStart..<bodyEnd)

        // Split path + query string.
        var path = target
        var query: [String: String] = [:]
        if let qIndex = target.firstIndex(of: "?") {
            path = String(target[..<qIndex])
            let queryString = String(target[target.index(after: qIndex)...])
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard let key = String(kv[0]).removingPercentEncoding else { continue }
                let value = kv.count == 2 ? (String(kv[1]).removingPercentEncoding ?? "") : ""
                query[key] = value
            }
        }
        path = path.removingPercentEncoding ?? path

        let consumedTotal = buffer.distance(from: buffer.startIndex, to: bodyEnd)
        let request = HTTPRequest(
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: body,
            remoteAddress: remoteAddress
        )
        return (request, consumedTotal)
    }
}
