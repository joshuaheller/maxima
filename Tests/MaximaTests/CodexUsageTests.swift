import Testing
import Foundation
@testable import Maxima

@Suite("Codex account limits")
struct CodexUsageTests {
    @Test("selects the account bucket and maps windows by duration, not position")
    func accountWindows() throws {
        let data = Data(#"{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300}},"rateLimitsByLimitId":{"codex_other":{"primary":{"usedPercent":91,"windowDurationMins":300}},"codex":{"primary":{"usedPercent":42.5,"windowDurationMins":10080,"resetsAt":1800000000},"secondary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1799990000}}}}"#.utf8)
        let snapshot = try CodexUsage.parse(data)
        #expect(snapshot.session?.percent == 12)
        #expect(snapshot.weekly?.percent == 43)
        #expect(snapshot.weekly?.resetsAt == Date(timeIntervalSince1970: 1800000000))
    }

    @Test("legacy bucket and partially missing windows remain usable")
    func legacy() throws {
        let snapshot = try CodexUsage.parse(Data(#"{"rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":300},"secondary":null}}"#.utf8))
        #expect(snapshot.session?.percent == 0)
        #expect(snapshot.session?.resetsAt == nil)
        #expect(snapshot.weekly == nil)
    }

    @Test("unknown and missing limits are never interpreted as zero", arguments: [
        #"{}"#,
        #"{"rateLimits":{"primary":{"windowDurationMins":300}}}"#,
        #"{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":15}}}"#,
        #"{"rateLimitsByLimitId":{"other":{"primary":{"usedPercent":20,"windowDurationMins":300}}}}"#
    ])
    func missing(body: String) {
        #expect(throws: CodexUsage.Failure.self) { _ = try CodexUsage.parse(Data(body.utf8)) }
    }

    @Test("compact countdown handles missing, expired, minute, hour and week boundaries")
    func countdowns() {
        let now = Date(timeIntervalSince1970: 10000)
        #expect(ResetCountdown.text(until: nil, now: now) == nil)
        for (seconds, text) in [(-10.0, "0m"), (1, "1m"), (3599, "1h"), (7200, "2h"), (86400, "1d"), (604800, "7d")] {
            #expect(ResetCountdown.text(until: now.addingTimeInterval(seconds), now: now) == text)
        }
    }
}
