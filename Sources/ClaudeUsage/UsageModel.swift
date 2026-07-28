import Foundation
import Observation
import os

/// Single source of truth for usage state and the refresh loop.
///
/// Keeps the last *good* snapshot across failures so the menu bar can show stale
/// numbers rather than nothing.
@MainActor
@Observable
public final class UsageModel {
    /// Last successfully parsed reading. Retained across failures.
    public private(set) var snapshot: UsageSnapshot?
    /// When `snapshot` was fetched.
    public private(set) var lastUpdated: Date?
    /// Error from the most recent attempt; nil after a success.
    public private(set) var lastError: UsageError?
    public private(set) var isRefreshing: Bool = false

    /// Seconds between refreshes after a successful fetch.
    public static let successInterval: TimeInterval = 300
    /// Shorter retry interval after a failure.
    public static let failureInterval: TimeInterval = 60

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let notifications: NotificationManager
    @ObservationIgnored private let log = Logger(subsystem: AppInfo.subsystem, category: "model")

    public init(notifications: NotificationManager = NotificationManager()) {
        self.notifications = notifications
    }

    /// Cancels the pending refresh. (There is no `deinit` cleanup: the model
    /// lives for the whole process, and a nonisolated `deinit` cannot touch the
    /// main-actor `Timer`.)
    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// True when the displayed numbers can no longer be trusted. A nil snapshot
    /// without an error is just the brief initial load, not a failure.
    public var isStale: Bool {
        lastError != nil
    }

    /// Derived input for the status bar renderer.
    public var displayState: StatusDisplayState {
        StatusDisplayState(
            all: snapshot?.allModels.map { BarState(percent: $0.percent, severity: $0.severity) },
            fable: snapshot?.fable.map { BarState(percent: $0.percent, severity: $0.severity) },
            isStale: isStale
        )
    }

    // MARK: Refresh loop

    public func start() {
        refresh(reason: "launch")
    }

    /// Kicks off a fetch unless one is already running.
    public func refresh(reason: String) {
        guard !isRefreshing else {
            log.debug("refresh(\(reason, privacy: .public)) skipped: already running")
            return
        }
        isRefreshing = true
        timer?.invalidate()
        timer = nil
        log.info("refresh started (\(reason, privacy: .public))")

        Task { [weak self] in
            let result = await Self.performFetch()
            guard let self else { return }
            self.apply(result)
        }
    }

    /// Off-main work: credential read + network call.
    private static func performFetch() async -> Result<UsageSnapshot, UsageError> {
        do {
            let credentials = try await KeychainCredentials.read()
            let snapshot = try await AnthropicAPI.fetchUsage(token: credentials.accessToken)
            return .success(FakePercents.apply(to: snapshot))
        } catch let error as CredentialError {
            return .failure(.credentials(error))
        } catch let error as UsageError {
            return .failure(error)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    private func apply(_ result: Result<UsageSnapshot, UsageError>) {
        isRefreshing = false
        switch result {
        case .success(let snapshot):
            self.snapshot = snapshot
            self.lastUpdated = Date()
            self.lastError = nil
            log.info("refresh succeeded")
            notifications.evaluate(snapshot)
            schedule(after: Self.successInterval)
        case .failure(let error):
            self.lastError = error
            log.error("refresh failed: \(error.userMessage, privacy: .public)")
            schedule(after: Self.failureInterval)
        }
    }

    /// One-shot timer, re-armed after every completion.
    private func schedule(after interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh(reason: "timer")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        log.debug("next refresh in \(Int(interval), privacy: .public)s")
    }
}
