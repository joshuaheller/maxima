import Foundation
import Security
import os

public enum CredentialError: Error, Sendable, Equatable {
    case notFound
    case accessDenied
    case malformed
    case expired(Date)

    public var userMessage: String {
        switch self {
        case .notFound:
            return "No Claude Code credentials found — sign in with Claude Code first"
        case .accessDenied:
            return "Keychain access was denied for the Claude Code credentials"
        case .malformed:
            return "Claude Code credentials could not be parsed"
        case .expired:
            return "Token expired — open Claude Code once to refresh it"
        }
    }
}

public struct Credentials: Sendable {
    public var accessToken: String
    public var expiresAt: Date?
    public var subscriptionType: String?
}

/// Reads Claude Code's OAuth access token from the login keychain.
///
/// Strictly read-only: the keychain item is owned by Claude Code, which rotates
/// the token, so it is re-read on *every* fetch and never written back. The
/// refresh token is deliberately never touched.
public enum KeychainCredentials {
    public static let service = "Claude Code-credentials"
    private static let log = Logger(subsystem: AppInfo.subsystem, category: "keychain")

    // MARK: Public entry point

    /// Reads credentials off the main actor.
    ///
    /// `readSync` blocks (it spawns a subprocess), so it is always hopped onto a
    /// detached task rather than relying on isolation-inheritance rules.
    public static func read() async throws -> Credentials {
        try await Task.detached(priority: .userInitiated) {
            try readSync()
        }.value
    }

    /// Blocking read. Do not call on the main thread.
    public static func readSync() throws -> Credentials {
        let json: Data
        do {
            json = try readViaSecurityTool()
        } catch {
            // The `security` CLI is the primary path because it never triggers a
            // GUI keychain prompt for an ad-hoc-signed binary. SecItemCopyMatching
            // does (on every rebuild), so it is only a fallback.
            log.warning("security(1) read failed, falling back to SecItemCopyMatching")
            json = try readViaSecItem()
        }
        return try decode(json)
    }

    // MARK: Primary — /usr/bin/security subprocess

    static func readViaSecurityTool() throws -> Data {
        // stdout goes to a temp file rather than a Pipe: a pipe would need a
        // concurrent drainer to avoid a full-buffer deadlock, and a file lets us
        // poll for termination with a hard timeout using only local state.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-usage-\(UUID().uuidString).json")
        FileManager.default.createFile(atPath: scratch.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: scratch) }

        guard let sink = try? FileHandle(forWritingTo: scratch) else {
            throw CredentialError.notFound
        }
        defer { try? sink.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        process.standardOutput = sink
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            log.error("could not launch /usr/bin/security: \(error.localizedDescription, privacy: .public)")
            throw CredentialError.notFound
        }

        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            log.error("security(1) timed out after 10s")
            throw CredentialError.notFound
        }
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            // 128 == user denied / interaction not allowed; 44 == item not found.
            throw process.terminationStatus == 128 ? CredentialError.accessDenied : CredentialError.notFound
        }

        guard let raw = try? Data(contentsOf: scratch) else {
            throw CredentialError.notFound
        }
        let trimmed = String(decoding: raw, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw CredentialError.notFound
        }
        return data
    }

    // MARK: Secondary — SecItemCopyMatching

    static func readViaSecItem() throws -> Data {
        func query(account: String?) -> [String: Any] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            if let account { query[kSecAttrAccount as String] = account }
            return query
        }

        for candidate in [NSUserName(), nil] {
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query(account: candidate) as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                if let data = item as? Data, !data.isEmpty { return data }
            case errSecItemNotFound:
                continue
            case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
                throw CredentialError.accessDenied
            default:
                log.error("SecItemCopyMatching failed with OSStatus \(status, privacy: .public)")
                continue
            }
        }
        throw CredentialError.notFound
    }

    // MARK: Decoding

    private struct Envelope: Decodable {
        struct OAuth: Decodable {
            var accessToken: String?
            var expiresAt: Double?
            var subscriptionType: String?
        }
        var claudeAiOauth: OAuth?
    }

    static func decode(_ data: Data, now: Date = Date()) throws -> Credentials {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: data),
              let oauth = envelope.claudeAiOauth,
              let token = oauth.accessToken,
              !token.isEmpty
        else {
            throw CredentialError.malformed
        }

        // expiresAt is epoch milliseconds.
        var expiry: Date?
        if let millis = oauth.expiresAt {
            let date = Date(timeIntervalSince1970: millis / 1000)
            expiry = date
            if date < now {
                throw CredentialError.expired(date)
            }
        }

        return Credentials(accessToken: token, expiresAt: expiry, subscriptionType: oauth.subscriptionType)
    }
}
