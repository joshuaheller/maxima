import Foundation
import os

// MARK: - Domain types

/// Severity of a usage limit, as reported by the API (with a percent-based fallback).
public enum Severity: String, Sendable, Comparable, CaseIterable {
    case normal
    case warning
    case critical

    /// Fallback used when the API omits `severity` or reports an unknown value.
    public static func fallback(percent: Int) -> Severity {
        if percent >= 95 { return .critical }
        if percent >= 80 { return .warning }
        return .normal
    }

    private var rank: Int {
        switch self {
        case .normal: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
}

/// Which limit a `UsageLimit` describes. The raw values double as stable
/// notification-dedup key components, so they must not change casually.
public enum LimitKind: String, Sendable {
    case allModels = "weekly_all"
    case fable = "weekly_fable"
    case session = "session"
    case codexSession = "codex_session"
    case codexWeekly = "codex_weekly"

    public var displayName: String {
        switch self {
        case .allModels: return "All models"
        case .fable: return "Fable"
        case .session: return "Current session"
        case .codexSession: return "Codex · 5 hours"
        case .codexWeekly: return "Codex · Weekly"
        }
    }

    public var isWeekly: Bool {
        switch self {
        case .allModels, .fable, .codexWeekly: return true
        case .session, .codexSession: return false
        }
    }
}

public struct UsageLimit: Sendable, Equatable {
    public var kind: LimitKind
    public var percent: Int
    public var severity: Severity
    public var resetsAt: Date?

    public init(kind: LimitKind, percent: Int, severity: Severity, resetsAt: Date?) {
        self.kind = kind
        self.percent = percent
        self.severity = severity
        self.resetsAt = resetsAt
    }

    /// Percent clamped to 0...100, as a 0...1 fraction, for drawing bars.
    public var fraction: Double {
        Double(min(max(percent, 0), 100)) / 100.0
    }
}

/// A complete, successfully parsed reading of the usage endpoint.
public struct UsageSnapshot: Sendable, Equatable {
    public var allModels: UsageLimit?
    public var fable: UsageLimit?
    public var session: UsageLimit?

    public init(allModels: UsageLimit?, fable: UsageLimit?, session: UsageLimit?) {
        self.allModels = allModels
        self.fable = fable
        self.session = session
    }

    public var weeklyLimits: [UsageLimit] {
        [allModels, fable].compactMap { $0 }
    }

    public var maxSeverity: Severity {
        [allModels, fable, session].compactMap { $0?.severity }.max() ?? .normal
    }
}

// MARK: - Errors

public enum UsageError: Error, Sendable, Equatable {
    case credentials(CredentialError)
    /// API rejected the token (HTTP 401/403).
    case unauthorized
    case httpStatus(Int)
    case network(String)
    case decoding(String)

    /// Human-readable, user-facing explanation.
    public var userMessage: String {
        switch self {
        case .credentials(let underlying):
            return underlying.userMessage
        case .unauthorized:
            return "Token rejected — open Claude Code once to refresh it"
        case .httpStatus(let code):
            return "Anthropic API returned HTTP \(code)"
        case .network(let detail):
            return "Network error: \(detail)"
        case .decoding(let detail):
            return "Could not read the usage response: \(detail)"
        }
    }
}

// MARK: - Wire format (decode only what we need, tolerant of everything else)

/// Top level of `GET /api/oauth/usage`. The real payload has many more fields;
/// they are intentionally ignored.
struct UsageResponseDTO: Decodable {
    var limits: [LimitDTO]?
}

struct LimitDTO: Decodable {
    var kind: String?
    var group: String?
    // Double: an integer-typed field would fail the whole decode if the server
    // ever sends a fractional percent (the sibling utilization fields are Doubles).
    var percent: Double?
    var severity: String?
    var resetsAt: String?
    var scope: ScopeDTO?
    var isActive: Bool?
}

struct ScopeDTO: Decodable {
    var model: ModelScopeDTO?
}

struct ModelScopeDTO: Decodable {
    var id: String?
    var displayName: String?
}

// MARK: - Parsing

public enum UsageParser {
    /// ISO8601 with fractional seconds, falling back to plain internet date-time.
    public static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    static func severity(raw: String?, percent: Int) -> Severity {
        if let raw, let parsed = Severity(rawValue: raw.lowercased()) { return parsed }
        return Severity.fallback(percent: percent)
    }

    static func limit(from dto: LimitDTO, as kind: LimitKind) -> UsageLimit {
        let percent = Int((dto.percent ?? 0).rounded())
        return UsageLimit(
            kind: kind,
            percent: percent,
            severity: severity(raw: dto.severity, percent: percent),
            resetsAt: parseDate(dto.resetsAt)
        )
    }

    /// Turns the raw JSON body into a snapshot.
    public static func parse(_ data: Data) throws -> UsageSnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let dto: UsageResponseDTO
        do {
            dto = try decoder.decode(UsageResponseDTO.self, from: data)
        } catch {
            throw UsageError.decoding(error.localizedDescription)
        }
        return snapshot(from: dto.limits ?? [])
    }

    static func snapshot(from limits: [LimitDTO]) -> UsageSnapshot {
        let all = limits.first { $0.kind == "weekly_all" }

        let scoped = limits.filter { $0.kind == "weekly_scoped" }
        // Prefer the explicitly Fable-scoped entry; otherwise take any weekly_scoped one.
        let fable = scoped.first { $0.scope?.model?.displayName == "Fable" } ?? scoped.first

        let session = limits.first { $0.kind == "session" }

        return UsageSnapshot(
            allModels: all.map { limit(from: $0, as: .allModels) },
            fable: fable.map { limit(from: $0, as: .fable) },
            session: session.map { limit(from: $0, as: .session) }
        )
    }
}

// MARK: - Network

public enum AnthropicAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let log = Logger(subsystem: AppInfo.subsystem, category: "api")

    /// Fetches and parses current usage. Runs off the main actor.
    public static func fetchUsage(token: String, session: URLSession = .shared) async throws -> UsageSnapshot {
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            log.error("usage request failed: \(error.localizedDescription, privacy: .public)")
            throw UsageError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300:
                break
            case 401, 403:
                log.error("usage request unauthorized (\(http.statusCode, privacy: .public))")
                throw UsageError.unauthorized
            default:
                log.error("usage request status \(http.statusCode, privacy: .public)")
                throw UsageError.httpStatus(http.statusCode)
            }
        }

        let snapshot = try UsageParser.parse(data)
        log.info("usage parsed: all=\(snapshot.allModels?.percent ?? -1, privacy: .public) fable=\(snapshot.fable?.percent ?? -1, privacy: .public) session=\(snapshot.session?.percent ?? -1, privacy: .public)")
        return snapshot
    }
}

// MARK: - Shared app identity

public enum AppInfo {
    public static let subsystem = "com.aucentiq.Maxima"
    public static let displayName = "Maxima"
}

// MARK: - Debug override

/// `MAXIMA_FAKE_PERCENTS="all,fable,session"` replaces the parsed percentages
/// after a successful fetch so colours and notifications can be eyeballed.
public enum FakePercents {
    public static let environmentKey = "MAXIMA_FAKE_PERCENTS"

    public static func apply(to snapshot: UsageSnapshot,
                            raw: String? = ProcessInfo.processInfo.environment[FakePercents.environmentKey]) -> UsageSnapshot {
        guard let raw, !raw.isEmpty else { return snapshot }
        let parts = raw.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        func override(_ limit: UsageLimit?, _ index: Int) -> UsageLimit? {
            guard var limit, index < parts.count, let value = parts[index] else { return limit }
            limit.percent = value
            limit.severity = Severity.fallback(percent: value)
            return limit
        }
        return UsageSnapshot(
            allModels: override(snapshot.allModels, 0),
            fable: override(snapshot.fable, 1),
            session: override(snapshot.session, 2)
        )
    }
}
