import Foundation

public enum OAuthError: Error, LocalizedError, Equatable {
    case launchFailed(String)
    case cancelled
    case timedOut
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let m): return "Could not start rclone: \(m)"
        case .cancelled: return "Sign-in cancelled"
        case .timedOut: return "Sign-in timed out. Try again and finish the browser step."
        case .failed(let m): return m.isEmpty ? "Sign-in failed" : "Sign-in failed: \(m)"
        }
    }
}

/// Browser sign-in for OAuth backends by running `rclone authorize <backend>`: rclone opens
/// the browser, waits for the consent redirect and prints the token JSON, which the caller
/// stores in the Keychain.
public final class OAuthAuthorizer {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false

    public init() {}

    /// Aborts a running `authorize`; the pending call throws `.cancelled`.
    public func cancel() {
        lock.lock(); cancelled = true; let p = process; lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    /// Returns the token JSON. `scope` reaches rclone as `RCLONE_<BACKEND>_SCOPE`; a custom
    /// client ID and secret (both required together) are passed as rclone arguments.
    public func authorize(
        binary: URL, backend: String, clientID: String? = nil, clientSecret: String? = nil,
        scope: String? = nil, timeout: TimeInterval = 300
    ) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                do {
                    cont.resume(returning: try self.run(
                        binary: binary, backend: backend, clientID: clientID,
                        clientSecret: clientSecret, scope: scope, timeout: timeout))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func run(
        binary: URL, backend: String, clientID: String?, clientSecret: String?,
        scope: String?, timeout: TimeInterval
    ) throws -> String {
        var args = ["authorize", backend]
        let id = (clientID ?? "").trimmingCharacters(in: .whitespaces)
        let secret = (clientSecret ?? "").trimmingCharacters(in: .whitespaces)
        // Half a pair used to fall back to rclone's shared client silently. That token only
        // works for an hour: the mount later refreshes it with *your* client and Google
        // answers `unauthorized_client`. Refuse instead.
        if id.isEmpty != secret.isEmpty {
            throw OAuthError.failed(id.isEmpty
                ? "A client secret was entered without a client ID. Enter both, or clear both to use rclone's shared client."
                : "Enter the client secret together with the client ID (Google does not show it again; add a new secret in the console), or clear the client ID.")
        }
        if !id.isEmpty { args += [id, secret] }
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        if let scope, !scope.isEmpty { env["RCLONE_\(backend.uppercased())_SCOPE"] = scope }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out

        lock.lock(); cancelled = false; timedOut = false; lock.unlock()
        do { try p.run() } catch { throw OAuthError.launchFailed(error.localizedDescription) }
        lock.lock(); process = p; lock.unlock()
        defer { lock.lock(); process = nil; lock.unlock() }

        let timer = DispatchWorkItem { [weak self] in
            guard let self, p.isRunning else { return }
            self.lock.lock(); self.timedOut = true; self.lock.unlock()
            p.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        let text = String(decoding: data, as: UTF8.self)

        if let token = Self.parseToken(from: text) { return token }
        lock.lock(); let wasCancelled = cancelled, wasTimedOut = timedOut; lock.unlock()
        if wasCancelled { throw OAuthError.cancelled }
        if wasTimedOut { throw OAuthError.timedOut }
        let tail = text.split(separator: "\n").suffix(3).joined(separator: "\n")
        throw OAuthError.failed(tail)
    }

    /// Extracts the token JSON from `rclone authorize` output. rclone prints it between
    /// "Paste the following into your remote machine --->" and "<---End paste".
    public static func parseToken(from output: String) -> String? {
        var candidate: String?
        if let start = output.range(of: "--->"), let end = output.range(of: "<---End paste"),
           start.upperBound <= end.lowerBound {
            candidate = String(output[start.upperBound..<end.lowerBound])
        } else {
            candidate = output.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("{") && $0.contains("access_token") }
        }
        guard let json = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !json.isEmpty,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["access_token"] is String || obj["refresh_token"] is String else { return nil }
        return json
    }
}
