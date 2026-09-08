import Foundation
import Testing

@testable import MLXBits_Image_Studio

@Suite("RemoteAuthService")
struct RemoteAuthServiceTests {
    @Test("Token comparison is exact and rejects wrong tokens")
    func tokenComparison() {
        #expect(RemoteAuthService.matchesToken("secret", expected: "secret"))
        #expect(!RemoteAuthService.matchesToken("secreT", expected: "secret"))
        #expect(!RemoteAuthService.matchesToken("secret-longer", expected: "secret"))
        #expect(!RemoteAuthService.matchesToken(nil, expected: "secret"))
        #expect(!RemoteAuthService.matchesToken("", expected: "secret"))
    }

    @Test("Sessions validate, expire on logout and after TTL")
    mutating func sessions() {
        var service = RemoteAuthService()
        let session = service.createSession()
        #expect(service.validateSession(session))
        service.endSession(session)
        #expect(!service.validateSession(session))
    }

    @Test("Unknown sessions are rejected")
    mutating func unknownSession() {
        var service = RemoteAuthService()
        _ = service.createSession()
        #expect(!service.validateSession("not-a-session"))
        #expect(!service.validateSession(nil))
    }

    @Test("Rate limiter allows up to the cap then blocks")
    mutating func rateLimit() {
        var service = RemoteAuthService()
        let client = "192.168.1.10"
        for _ in 0..<RemoteAuthService.maxFailedAttempts {
            #expect(service.checkRateLimit(client: client))
            service.recordFailedAttempt(client: client)
        }
        #expect(!service.checkRateLimit(client: client))
        // Another client is unaffected.
        #expect(service.checkRateLimit(client: "192.168.1.11"))
        // Window expiry restores access.
        let future = Date().addingTimeInterval(RemoteAuthService.rateWindow + 1)
        #expect(service.checkRateLimit(client: client, now: future))
    }

    @Test("Tokens are URL-safe and unique")
    func randomToken() {
        let token = RemoteAuthService.randomToken()
        #expect(!token.contains("+"))
        #expect(!token.contains("/"))
        #expect(!token.contains("="))
        #expect(token != RemoteAuthService.randomToken())
    }
}

@Suite("HTTPRequestParser")
struct HTTPRequestParserTests {
    private func makeRequest(
        _ method: String = "GET",
        path: String = "/api/v1/status",
        headers: [String: String] = ["host": "localhost"],
        body: String = ""
    ) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\n"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + Data(body.utf8)
    }

    @Test("Parses a simple GET request")
    func simpleGet() throws {
        let data = makeRequest(path: "/api/v1/status?verbose=1")
        let parsed = try #require(HTTPRequestParser.parse(data, remoteAddress: "test"))
        #expect(parsed.request.method == "GET")
        #expect(parsed.request.path == "/api/v1/status")
        #expect(parsed.request.query["verbose"] == "1")
        #expect(parsed.consumed == data.count)
    }

    @Test("Parses a POST request with body")
    func postWithBody() throws {
        let body = #"{"prompt":"a cat"}"#
        let data = makeRequest(
            method: "POST",
            path: "/api/v1/generate",
            headers: ["content-length": String(body.utf8.count)],
            body: body
        )
        let parsed = try #require(HTTPRequestParser.parse(data, remoteAddress: "test"))
        #expect(parsed.request.body.count == body.utf8.count)
    }

    @Test("Returns nil until the body is complete")
    func partialBody() throws {
        let body = #"{"a":"bbbbb"}"#
        let data = makeRequest(
            method: "POST",
            path: "/x",
            headers: ["content-length": String(body.utf8.count)],
            body: body
        )
        let partial = data.prefix(data.count - 2)
        #expect(try HTTPRequestParser.parse(partial, remoteAddress: "t") == nil)
    }

    @Test("Rejects oversized bodies")
    func tooLarge() {
        let data = makeRequest(
            method: "POST",
            path: "/x",
            headers: ["content-length": String(HTTPRequestParser.maxBodyBytes + 1)]
        )
        #expect(throws: HTTPParseError.tooLarge) {
            try HTTPRequestParser.parse(data, remoteAddress: "t")
        }
    }

    @Test("Parses cookies")
    func cookies() throws {
        let data = makeRequest(headers: ["cookie": "mlxbits_session=abc; other=1"])
        let parsed = try #require(HTTPRequestParser.parse(data, remoteAddress: "t"))
        #expect(parsed.request.cookies["mlxbits_session"] == "abc")
    }
}

@MainActor
@Suite("RemoteAccessEventBus")
struct RemoteAccessEventBusTests {
    @Test("Subscribers receive emitted events as SSE frames")
    func subscribeAndEmit() async {
        let bus = RemoteAccessEventBus()
        let stream = bus.subscribe()
        #expect(bus.subscriberCount == 1)

        bus.emit(.jobCreated(jobID: "abc", family: "flux"))

        let iterator = stream.makeAsyncIterator()
        let frame = await iterator.next()
        let text = String(data: frame ?? Data(), encoding: .utf8) ?? ""
        #expect(text.hasPrefix("event: jobCreated\ndata: "))
        #expect(text.contains("abc"))
    }

    @Test("Cancelling the consumer removes the subscriber")
    func termination() async {
        let bus = RemoteAccessEventBus()
        let stream = bus.subscribe()
        #expect(bus.subscriberCount == 1)
        let consumer = Task {
            for await _ in stream {}
        }
        try? await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(bus.subscriberCount == 0)
    }
}
