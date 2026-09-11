import Foundation
import UserNotifications
import os

/// Fires a local notification the first time a *weekly* limit enters warning and
/// again when it enters critical — at most once per severity per reset window.
@MainActor
public final class NotificationManager {
    private let defaults: UserDefaults
    private let log = Logger(subsystem: AppInfo.subsystem, category: "notifications")

    /// UserNotifications APIs require a real bundle; from a bare binary they
    /// no-op or trap, so every call is gated on this.
    private let isBundled: Bool

    public init(defaults: UserDefaults = .standard,
                isBundled: Bool = Bundle.main.bundleIdentifier != nil) {
        self.defaults = defaults
        self.isBundled = isBundled
    }

    // MARK: Authorization

    public func requestAuthorization() {
        guard isBundled else {
            log.info("skipping notification authorization: not running from a bundle")
            return
        }
        // The completion-handler form calls back on UserNotifications' own queue.
        // Inside this @MainActor type the closure is inferred main-actor-isolated
        // (the SDK does not mark the parameter @Sendable), so Swift 6's runtime
        // executor check traps with SIGTRAP the moment it fires. The async form
        // suspends and resumes on the main actor instead.
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
                log.info("authorization granted=\(granted, privacy: .public)")
            } catch {
                log.error("authorization failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Evaluation

    public func evaluate(_ snapshot: UsageSnapshot) {
        for limit in snapshot.weeklyLimits where limit.severity != .normal {
            let key = Self.dedupKey(kind: limit.kind, resetsAt: limit.resetsAt, severity: limit.severity)
            guard !defaults.bool(forKey: key) else { continue }
            defaults.set(true, forKey: key)
            log.info("firing \(limit.severity.rawValue, privacy: .public) notification for \(limit.kind.rawValue, privacy: .public) at \(limit.percent, privacy: .public)%")
            fire(for: limit)
        }
    }

    /// `notified.<kind>.<resetsAtISO8601>.<severity>`
    public static func dedupKey(kind: LimitKind, resetsAt: Date?, severity: Severity) -> String {
        "notified.\(kind.rawValue).\(iso(resetsAt)).\(severity.rawValue)"
    }

    private static func iso(_ date: Date?) -> String {
        guard let date else { return "unknown" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func fire(for limit: UsageLimit) {
        guard isBundled else { return }

        let content = UNMutableNotificationContent()
        content.title = limit.severity == .critical
            ? "\(limit.displayNameForNotification) limit almost exhausted"
            : "\(limit.displayNameForNotification) limit running low"
        var body = "\(limit.percent)% of your weekly limit used."
        if let resetsAt = limit.resetsAt {
            body += " Resets \(Self.resetDescription(resetsAt))."
        }
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: Self.dedupKey(kind: limit.kind, resetsAt: limit.resetsAt, severity: limit.severity),
            content: content,
            trigger: nil
        )
        // Same isolation trap as requestAuthorization() above — use the async form.
        Task {
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                log.error("failed to post notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func resetDescription(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

extension UsageLimit {
    var displayNameForNotification: String {
        switch kind {
        case .allModels: return "All models weekly"
        case .fable: return "Fable weekly"
        case .session: return "Session"
        case .codexSession: return "Codex 5 hours"
        case .codexWeekly: return "Codex weekly"
        }
    }
}
