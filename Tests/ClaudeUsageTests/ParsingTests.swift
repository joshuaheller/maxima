import Testing
import Foundation
import AppKit
@testable import ClaudeUsage

// A trimmed-but-realistic capture of a live `GET /api/oauth/usage` response,
// including the many top-level fields the app deliberately ignores.
private let liveFixture = """
{
  "five_hour": { "utilization": 10.0, "resets_at": "2026-07-28T14:00:00.100991+00:00", "limit_dollars": null },
  "seven_day": { "utilization": 27.0, "resets_at": "2026-08-02T00:00:00.101018+00:00", "used_dollars": null },
  "seven_day_oauth_apps": null,
  "seven_day_opus": null,
  "tangelo": null,
  "iguana_necktie": null,
  "extra_usage": { "is_enabled": false, "monthly_limit": null, "user_disabled": true },
  "limits": [
    {
      "kind": "session", "group": "session", "percent": 10, "severity": "normal",
      "resets_at": "2026-07-28T14:00:00.100991+00:00", "scope": null, "is_active": false
    },
    {
      "kind": "weekly_all", "group": "weekly", "percent": 27, "severity": "normal",
      "resets_at": "2026-08-02T00:00:00.101018+00:00", "scope": null, "is_active": false
    },
    {
      "kind": "weekly_scoped", "group": "weekly", "percent": 28, "severity": "normal",
      "resets_at": "2026-08-02T00:00:00.101409+00:00",
      "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null },
      "is_active": true
    }
  ],
  "spend": { "used": { "amount_minor": 0, "currency": "USD", "exponent": 2 }, "percent": 0, "severity": "normal" },
  "member_dashboard_available": false
}
""".data(using: .utf8)!

// MARK: - Response decoding

@Suite("Usage response parsing")
struct UsageParsingTests {

    @Test("decodes the live fixture, ignoring unknown top-level fields")
    func decodesLiveFixture() throws {
        let snapshot = try UsageParser.parse(liveFixture)

        #expect(snapshot.allModels?.percent == 27)
        #expect(snapshot.allModels?.kind == .allModels)
        #expect(snapshot.allModels?.severity == .normal)

        #expect(snapshot.fable?.percent == 28)
        #expect(snapshot.fable?.kind == .fable)

        #expect(snapshot.session?.percent == 10)
        #expect(snapshot.session?.kind == .session)
    }

    @Test("parses reset timestamps into real dates")
    func parsesResetDates() throws {
        let snapshot = try UsageParser.parse(liveFixture)
        let resets = try #require(snapshot.allModels?.resetsAt)
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 2
        components.hour = 0; components.minute = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let expected = try #require(calendar.date(from: components))
        #expect(abs(resets.timeIntervalSince(expected)) < 1)
    }

    @Test("tolerates a payload with no limits array")
    func tolerantOfMissingLimits() throws {
        let snapshot = try UsageParser.parse(Data(#"{"member_dashboard_available": false}"#.utf8))
        #expect(snapshot.allModels == nil)
        #expect(snapshot.fable == nil)
        #expect(snapshot.session == nil)
    }

    @Test("reports malformed JSON as a decoding error")
    func rejectsGarbage() {
        #expect(throws: UsageError.self) {
            _ = try UsageParser.parse(Data("not json".utf8))
        }
    }
}

// MARK: - Fable matching

@Suite("Fable limit selection")
struct FableMatchingTests {

    private func scoped(_ displayName: String?, percent: Int) -> LimitDTO {
        LimitDTO(
            kind: "weekly_scoped", group: "weekly", percent: percent, severity: "normal",
            resetsAt: "2026-08-02T00:00:00.000000+00:00",
            scope: ScopeDTO(model: ModelScopeDTO(id: nil, displayName: displayName)),
            isActive: true
        )
    }

    @Test("prefers the scoped limit whose model is named Fable")
    func matchesFableByName() {
        let snapshot = UsageParser.snapshot(from: [
            scoped("Sonnet", percent: 11),
            scoped("Fable", percent: 42),
        ])
        #expect(snapshot.fable?.percent == 42)
    }

    @Test("falls back to any weekly_scoped limit when Fable is absent")
    func fallsBackToFirstScoped() {
        let snapshot = UsageParser.snapshot(from: [
            scoped("Sonnet", percent: 11),
            scoped(nil, percent: 12),
        ])
        #expect(snapshot.fable?.percent == 11)
        #expect(snapshot.fable?.kind == .fable)
    }

    @Test("yields no Fable limit when there is no scoped entry at all")
    func noScopedEntry() {
        let snapshot = UsageParser.snapshot(from: [
            LimitDTO(kind: "weekly_all", group: "weekly", percent: 5, severity: "normal",
                     resetsAt: nil, scope: nil, isActive: false)
        ])
        #expect(snapshot.fable == nil)
        #expect(snapshot.allModels?.percent == 5)
    }
}

// MARK: - Severity

@Suite("Severity handling")
struct SeverityTests {

    @Test("uses the API-reported severity when it is recognised")
    func usesReportedSeverity() {
        #expect(UsageParser.severity(raw: "critical", percent: 3) == .critical)
        #expect(UsageParser.severity(raw: "WARNING", percent: 3) == .warning)
    }

    @Test(
        "falls back to percent thresholds when severity is missing or unknown",
        arguments: [
            (0, Severity.normal), (79, .normal), (80, .warning), (94, .warning),
            (95, .critical), (100, .critical), (140, .critical),
        ]
    )
    func fallsBackByPercent(percent: Int, expected: Severity) {
        #expect(UsageParser.severity(raw: nil, percent: percent) == expected)
        #expect(UsageParser.severity(raw: "sideways", percent: percent) == expected)
    }

    @Test("orders severities so the worst one wins")
    func severityOrdering() {
        #expect(Severity.normal < .warning)
        #expect(Severity.warning < .critical)
        let snapshot = UsageSnapshot(
            allModels: UsageLimit(kind: .allModels, percent: 10, severity: .normal, resetsAt: nil),
            fable: UsageLimit(kind: .fable, percent: 99, severity: .critical, resetsAt: nil),
            session: nil
        )
        #expect(snapshot.maxSeverity == .critical)
    }
}

// MARK: - Date parsing

@Suite("ISO8601 date parsing")
struct DateParsingTests {

    @Test("parses timestamps with fractional seconds")
    func withFractionalSeconds() throws {
        let date = try #require(UsageParser.parseDate("2026-08-02T00:00:00.101018+00:00"))
        #expect(abs(date.timeIntervalSince1970 - 1785628800.101018) < 0.01)
    }

    @Test("parses timestamps without fractional seconds")
    func withoutFractionalSeconds() throws {
        let date = try #require(UsageParser.parseDate("2026-08-02T00:00:00Z"))
        #expect(abs(date.timeIntervalSince1970 - 1785628800) < 0.01)
    }

    @Test("returns nil for nil, empty and unparsable input", arguments: [nil, "", "yesterday"])
    func rejectsBadInput(raw: String?) {
        #expect(UsageParser.parseDate(raw) == nil)
    }
}

// MARK: - Notification dedup

@MainActor
@Suite("Notification dedup")
struct NotificationDedupTests {

    private func makeDefaults() throws -> UserDefaults {
        let name = "ClaudeUsageTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("dedup key format is notified.<kind>.<resetsAtISO8601>.<severity>")
    func keyFormat() {
        let resets = Date(timeIntervalSince1970: 1785628800)
        let key = NotificationManager.dedupKey(kind: .allModels, resetsAt: resets, severity: .warning)
        #expect(key == "notified.weekly_all.2026-08-02T00:00:00Z.warning")

        let fableKey = NotificationManager.dedupKey(kind: .fable, resetsAt: resets, severity: .critical)
        #expect(fableKey == "notified.weekly_fable.2026-08-02T00:00:00Z.critical")
    }

    @Test("key tolerates a missing reset date")
    func keyWithoutResetDate() {
        #expect(NotificationManager.dedupKey(kind: .fable, resetsAt: nil, severity: .warning)
                == "notified.weekly_fable.unknown.warning")
    }

    @Test("marks each severity at most once per reset window")
    func firesOncePerSeverity() throws {
        let defaults = try makeDefaults()
        let manager = NotificationManager(defaults: defaults, isBundled: false)
        let resets = Date(timeIntervalSince1970: 1785628800)

        let warningSnapshot = UsageSnapshot(
            allModels: UsageLimit(kind: .allModels, percent: 82, severity: .warning, resetsAt: resets),
            fable: UsageLimit(kind: .fable, percent: 10, severity: .normal, resetsAt: resets),
            session: nil
        )
        manager.evaluate(warningSnapshot)
        #expect(defaults.bool(forKey: "notified.weekly_all.2026-08-02T00:00:00Z.warning"))
        #expect(defaults.bool(forKey: "notified.weekly_fable.2026-08-02T00:00:00Z.warning") == false)

        // Escalating to critical marks a new key; the warning key stays set.
        let criticalSnapshot = UsageSnapshot(
            allModels: UsageLimit(kind: .allModels, percent: 97, severity: .critical, resetsAt: resets),
            fable: nil,
            session: nil
        )
        manager.evaluate(criticalSnapshot)
        #expect(defaults.bool(forKey: "notified.weekly_all.2026-08-02T00:00:00Z.critical"))

        // A new reset window gets its own keys.
        let nextWindow = Date(timeIntervalSince1970: 1786233600)
        manager.evaluate(UsageSnapshot(
            allModels: UsageLimit(kind: .allModels, percent: 82, severity: .warning, resetsAt: nextWindow),
            fable: nil, session: nil
        ))
        #expect(defaults.bool(forKey: "notified.weekly_all.2026-08-09T00:00:00Z.warning"))
    }

    @Test("never notifies for the session limit")
    func ignoresSessionLimit() throws {
        let defaults = try makeDefaults()
        let manager = NotificationManager(defaults: defaults, isBundled: false)
        let resets = Date(timeIntervalSince1970: 1785628800)
        manager.evaluate(UsageSnapshot(
            allModels: nil, fable: nil,
            session: UsageLimit(kind: .session, percent: 99, severity: .critical, resetsAt: resets)
        ))
        #expect(defaults.bool(forKey: "notified.session.2026-08-02T00:00:00Z.critical") == false)
    }
}

// MARK: - Credentials

@Suite("Credential decoding")
struct CredentialTests {

    private func envelope(expiresAt: Double) -> Data {
        Data("""
        {"mcpOAuth":{"some-server":{"accessToken":"other"}},
         "claudeAiOauth":{"accessToken":"sk-ant-oat-test","refreshToken":"sk-ant-ort-test",
         "expiresAt":\(Int(expiresAt)),"scopes":["user:inference"],"subscriptionType":"max"}}
        """.utf8)
    }

    @Test("extracts the access token and subscription, ignoring sibling entries")
    func decodesEnvelope() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let credentials = try KeychainCredentials.decode(envelope(expiresAt: 1_800_000_000_000), now: now)
        #expect(credentials.accessToken == "sk-ant-oat-test")
        #expect(credentials.subscriptionType == "max")
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test("treats an elapsed expiry as expired")
    func detectsExpiry() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        #expect(throws: CredentialError.expired(Date(timeIntervalSince1970: 1_800_000_000))) {
            _ = try KeychainCredentials.decode(envelope(expiresAt: 1_800_000_000_000), now: now)
        }
    }

    @Test("rejects a blob without a claudeAiOauth access token")
    func rejectsMalformed() {
        #expect(throws: CredentialError.malformed) {
            _ = try KeychainCredentials.decode(Data(#"{"mcpOAuth":{}}"#.utf8))
        }
    }

    @Test("expired-token message points the user back at Claude Code")
    func expiryMessage() {
        let message = UsageError.credentials(.expired(.now)).userMessage
        #expect(message == "Token expired — open Claude Code once to refresh it")
        #expect(UsageError.unauthorized.userMessage.contains("open Claude Code once"))
    }
}

// MARK: - Fake percent override

@Suite("Fake percent override")
struct FakePercentTests {

    private let base = UsageSnapshot(
        allModels: UsageLimit(kind: .allModels, percent: 27, severity: .normal, resetsAt: nil),
        fable: UsageLimit(kind: .fable, percent: 28, severity: .normal, resetsAt: nil),
        session: UsageLimit(kind: .session, percent: 10, severity: .normal, resetsAt: nil)
    )

    @Test("overrides percentages and recomputes severity")
    func appliesOverride() {
        let result = FakePercents.apply(to: base, raw: "85,97,50")
        #expect(result.allModels?.percent == 85)
        #expect(result.allModels?.severity == .warning)
        #expect(result.fable?.percent == 97)
        #expect(result.fable?.severity == .critical)
        #expect(result.session?.percent == 50)
        #expect(result.session?.severity == .normal)
    }

    @Test("leaves the snapshot untouched when unset")
    func noOverride() {
        #expect(FakePercents.apply(to: base, raw: nil) == base)
        #expect(FakePercents.apply(to: base, raw: "") == base)
    }
}

// MARK: - Renderer state

@Suite("Status bar display state")
struct DisplayStateTests {

    @Test("template rendering only while fresh and all-normal")
    func templateEligibility() {
        let normal = StatusDisplayState(all: BarState(percent: 26, severity: .normal),
                                        fable: BarState(percent: 28, severity: .normal),
                                        isStale: false)
        #expect(normal.isTemplateEligible)

        var warned = normal
        warned.all = BarState(percent: 85, severity: .warning)
        #expect(warned.isTemplateEligible == false)

        var stale = normal
        stale.isStale = true
        #expect(stale.isTemplateEligible == false)
    }

    @Test("bar fill fraction is clamped to 0...1")
    func clampsFraction() {
        #expect(BarState(percent: -10, severity: .normal).fraction == 0)
        #expect(BarState(percent: 140, severity: .critical).fraction == 1)
        #expect(BarState(percent: 26, severity: .normal).fraction == 0.26)
    }

    @Test("stale state widens the canvas for the warning glyph")
    func staleWidth() {
        #expect(StatusBarRenderer.width(isStale: false) == 68)
        // The stale glyph is extra width, so the bars keep their size.
        #expect(StatusBarRenderer.width(isStale: true) - StatusBarRenderer.width(isStale: false) == 10)
    }

    @Test("the percent column fits the widest label it can show", arguments: ["0%", "26%", "100%"])
    func percentTextFits(label: String) {
        let width = (label as NSString).size(withAttributes: [.font: StatusBarRenderer.percentFont]).width
        #expect(width <= StatusBarRenderer.textWidth)
    }
}
