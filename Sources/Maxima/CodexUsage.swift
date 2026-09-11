import Foundation

/// Uses Codex's supported local JSON-RPC interface; credentials stay owned by Codex.
enum CodexUsage {
    struct Snapshot: Sendable, Equatable {
        var session: UsageLimit?
        var weekly: UsageLimit?
    }

    struct Response: Decodable {
        var rateLimits: Bucket?
        var rateLimitsByLimitId: [String: Bucket]?
    }
    struct Bucket: Decodable {
        var primary: Window?
        var secondary: Window?
    }
    struct Window: Decodable {
        var usedPercent: Double?
        var windowDurationMins: Int?
        var resetsAt: Double?
    }
    enum Failure: Error, LocalizedError {
        case unavailable, connection, response, noWindows
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Codex not found — install Codex and sign in with ChatGPT."
            case .connection: return "Codex did not respond. Open Codex and try again."
            case .response: return "Could not read Codex limits. Check your ChatGPT login in Codex."
            case .noWindows: return "No 5-hour or weekly Codex limits available for this account."
            }
        }
    }

    static func parse(_ data: Data) throws -> Snapshot {
        let response = try JSONDecoder().decode(Response.self, from: data)
        // Never substitute a model-specific bucket for the account-wide Codex bucket.
        let bucket = response.rateLimitsByLimitId?["codex"] ??
            (response.rateLimitsByLimitId == nil ? response.rateLimits : nil)
        let windows = [bucket?.primary, bucket?.secondary].compactMap { $0 }
        func limit(minutes: Int, kind: LimitKind) -> UsageLimit? {
            guard let window = windows.first(where: { $0.windowDurationMins == minutes }),
                  let used = window.usedPercent, used.isFinite else { return nil }
            let percent = Int(min(100, max(0, used)).rounded())
            return UsageLimit(kind: kind, percent: percent, severity: .fallback(percent: percent),
                              resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) })
        }
        let snapshot = Snapshot(session: limit(minutes: 300, kind: .codexSession),
                                weekly: limit(minutes: 10080, kind: .codexWeekly))
        guard snapshot.session != nil || snapshot.weekly != nil else { throw Failure.noWindows }
        return snapshot
    }

    static func fetch() async throws -> Snapshot {
        try await Task.detached(priority: .utility) { try fetchSync() }.value
    }

    private static func fetchSync() throws -> Snapshot {
        let paths = ["/Applications/Codex.app/Contents/Resources/codex",
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path,
                     "/opt/homebrew/bin/codex", "/usr/local/bin/codex"] +
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw Failure.unavailable
        }
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // A hard deadline also releases a blocked pipe read if the server stops responding.
        let deadline = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: deadline)
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            deadline.cancel()
            try? output.fileHandleForReading.close()
        }
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "maxima", "version": "1.0"]]])
        var buffer = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { throw Failure.connection }
            buffer.append(chunk)
            guard buffer.count < 2_000_000 else { throw Failure.response }
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = message["id"] as? Int else { continue }
                guard message["error"] == nil else { throw Failure.response }
                if id == 1 {
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/rateLimits/read"])
                } else if id == 2, let result = message["result"] {
                    return try parse(JSONSerialization.data(withJSONObject: result))
                }
            }
        }
    }
}

/// Short, rounded-up remaining time; precise reset dates live in the popover.
enum ResetCountdown {
    static func text(until date: Date?, now: Date = .now) -> String? {
        guard let date else { return nil }
        let minutes = max(0, Int(ceil(date.timeIntervalSince(now) / 60)))
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 1440 { return "\(Int(ceil(Double(minutes) / 60)))h" }
        return "\(Int(ceil(Double(minutes) / 1440)))d"
    }
}
