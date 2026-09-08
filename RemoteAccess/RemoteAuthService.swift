import Foundation

/// Session + token auth for the remote web UI. Pure logic, unit-testable.
/// The access token itself lives in the macOS Keychain (via `KeychainHelper`);
/// only derived, in-memory session cookies live here.
struct RemoteAuthService {
    struct Session {
        let id: String
        let createdAt: Date
        let lastSeenAt: Date
    }

    /// Sessions expire after this much inactivity.
    static let sessionTTL: TimeInterval = 30 * 24 * 60 * 60  // 30 jours
    /// Window for the login rate limiter.
    static let rateWindow: TimeInterval = 60
    /// Failed attempts allowed per window per client.
    static let maxFailedAttempts = 8

    private var sessions: [String: Session] = [:]
    private var failedAttempts: [(client: String, at: Date)] = []

    // MARK: - Sessions

    mutating func createSession() -> String {
        let id = Self.randomToken()
        sessions[id] = Session(id: id, createdAt: Date(), lastSeenAt: Date())
        pruneSessions()
        return id
    }

    mutating func validateSession(_ cookieValue: String?) -> Bool {
        guard let id = cookieValue, let session = sessions[id] else { return false }
        if Date().timeIntervalSince(session.lastSeenAt) > Self.sessionTTL {
            sessions.removeValue(forKey: id)
            return false
        }
        sessions[id] = Session(id: id, createdAt: session.createdAt, lastSeenAt: Date())
        return true
    }

    mutating func endSession(_ cookieValue: String?) {
        if let id = cookieValue { sessions.removeValue(forKey: id) }
    }

    mutating func endAllSessions() {
        sessions.removeAll()
    }

    var sessionCount: Int { sessions.count }

    // MARK: - Token check

    /// Bearer-token auth for programmatic API clients (external Web UI mode).
    static func matchesToken(_ presented: String?, expected: String) -> Bool {
        guard let presented, !presented.isEmpty else { return false }
        // Constant-time-ish comparison; token lengths are equal for honest clients.
        guard presented.count == expected.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(presented.utf8, expected.utf8) {
            difference |= a ^ b
        }
        return difference == 0
    }

    // MARK: - Login rate limiting

    mutating func checkRateLimit(client: String, now: Date = Date()) -> Bool {
        failedAttempts.removeAll { now.timeIntervalSince($0.at) > Self.rateWindow }
        return failedAttempts.filter { $0.client == client }.count < Self.maxFailedAttempts
    }

    mutating func recordFailedAttempt(client: String, now: Date = Date()) {
        failedAttempts.append((client, now))
    }

    mutating func clearFailures(client: String) {
        failedAttempts.removeAll { $0.client == client }
    }

    // MARK: - Helpers

    private mutating func pruneSessions() {
        let cutoff = Date().addingTimeInterval(-Self.sessionTTL)
        sessions = sessions.filter { $0.value.lastSeenAt > cutoff }
    }

    static func randomToken(byteCount: Int = 24) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64URLEncodedString()
    }
}

extension Data {
    /// URL-safe base64 (no padding) — safe in cookies and URLs.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Cookie name shared by the login endpoint and the auth middleware.
enum RemoteAuthCookie {
    static let name = "mlxbits_session"
}
