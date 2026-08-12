import Foundation
import os

/// Recovers from an expired access token without breaking Maxima's read-only
/// contract with the keychain.
///
/// Maxima deliberately never refreshes the token itself: the credential item
/// belongs to Claude Code, and touching the refresh token or writing the item back
/// is out of scope (see CONTRIBUTING.md). Instead it asks Claude Code to do it, by
/// running a single non-interactive `claude -p`. That refreshes the token on
/// start-up — Claude Code owns the OAuth flow, handles refresh-token rotation, and
/// re-stores the item — then exits on its own. Maxima simply re-reads afterwards.
enum TokenRefresher {
    private static let log = Logger(subsystem: AppInfo.subsystem, category: "refresher")

    /// Runs `claude -p` once. Returns true if it exited cleanly (the token was very
    /// likely refreshed). Never throws: a missing CLI, a launch failure, or a
    /// timeout all resolve to false, so the caller just keeps showing the manual hint.
    static func nudge() async -> Bool {
        await Task.detached(priority: .utility) { runNudge() }.value
    }

    private static func runNudge() -> Bool {
        guard let claude = locate() else {
            log.info("claude CLI not found on PATH; cannot auto-refresh")
            return false
        }

        let process = Process()
        process.executableURL = claude
        // A throwaway prompt: the point is the start-up token refresh, not the reply.
        process.arguments = ["-p", "ok"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            log.error("could not launch claude: \(error.localizedDescription, privacy: .public)")
            return false
        }

        // Hard ceiling so a stuck or login-required invocation can never hang the app.
        let deadline = Date().addingTimeInterval(45)
        while process.isRunning && Date() < deadline {
            usleep(100_000)
        }
        if process.isRunning {
            process.terminate()
            log.error("claude -p timed out after 45s; terminated")
            return false
        }
        process.waitUntilExit()

        let ok = process.terminationStatus == 0
        log.info("claude -p exited with status \(process.terminationStatus, privacy: .public)")
        return ok
    }

    /// Finds the `claude` executable. A GUI (launchd) process gets a minimal PATH
    /// that usually excludes `~/.local/bin`, so check the common install locations
    /// directly and fall back to the user's login shell.
    private static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            URL(fileURLWithPath: "/usr/bin/claude"),
        ]
        for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        return locateViaLoginShell()
    }

    private static func locateViaLoginShell() -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}

extension UsageError {
    /// True when the token is present but no longer accepted — the one failure a
    /// Claude Code refresh can actually fix.
    var isExpiredToken: Bool {
        switch self {
        case .unauthorized, .credentials(.expired):
            return true
        default:
            return false
        }
    }
}
