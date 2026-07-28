import AppKit
import Foundation

// Entry point. Two headless debug modes short-circuit before any UI is created;
// anything else launches the menu-bar agent.

let arguments = CommandLine.arguments

if arguments.contains("--fetch-once") {
    CLI.runFetchOnce()
} else if let index = arguments.firstIndex(of: "--render-test") {
    let directory = index + 1 < arguments.count ? arguments[index + 1] : FileManager.default.currentDirectoryPath
    CLI.runRenderTest(directory: directory)
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menu-bar only: no Dock icon, no menu bar app menu.
    app.setActivationPolicy(.accessory)
    app.run()
}

// MARK: - Debug entry points

enum CLI {
    /// `--fetch-once`: read credentials, fetch, print the parsed limits. No AppKit,
    /// no UserNotifications — safe to run from a bare binary in a terminal.
    static func runFetchOnce() -> Never {
        let semaphore = DispatchSemaphore(value: 0)
        // Detached: the main thread blocks below, so a main-actor task would deadlock.
        Task.detached {
            do {
                let credentials = try KeychainCredentials.readSync()
                let snapshot = FakePercents.apply(
                    to: try await AnthropicAPI.fetchUsage(token: credentials.accessToken)
                )
                if let subscription = credentials.subscriptionType {
                    print("subscription: \(subscription)")
                }
                for limit in [snapshot.allModels, snapshot.fable, snapshot.session].compactMap({ $0 }) {
                    print(describe(limit))
                }
                semaphore.signal()
                exit(0)
            } catch {
                let message = (error as? UsageError)?.userMessage
                    ?? (error as? CredentialError)?.userMessage
                    ?? error.localizedDescription
                FileHandle.standardError.write(Data("error: \(message)\n".utf8))
                semaphore.signal()
                exit(1)
            }
        }
        semaphore.wait()
        exit(0)
    }

    private static func describe(_ limit: UsageLimit) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = .current
        let resets = limit.resetsAt.map { formatter.string(from: $0) } ?? "unknown"
        let kind = limit.kind.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)
        let percent = String(format: "%3d%%", limit.percent)
        let severity = limit.severity.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
        return "\(kind) \(percent)  \(severity) resets \(resets)"
    }

    /// `--render-test <dir>`: write PNGs of the status image for a few states so
    /// the drawing can be eyeballed without launching the GUI.
    static func runRenderTest(directory: String) -> Never {
        let cases: [(String, StatusDisplayState)] = [
            ("normal-26-28", .init(all: .init(percent: 26, severity: .normal),
                                   fable: .init(percent: 28, severity: .normal),
                                   isStale: false)),
            ("warning-85-60", .init(all: .init(percent: 85, severity: .warning),
                                    fable: .init(percent: 60, severity: .normal),
                                    isStale: false)),
            ("critical-97-90", .init(all: .init(percent: 97, severity: .critical),
                                     fable: .init(percent: 90, severity: .warning),
                                     isStale: false)),
            ("stale-26-28", .init(all: .init(percent: 26, severity: .normal),
                                  fable: .init(percent: 28, severity: .normal),
                                  isStale: true)),
        ]

        let url = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }

        let appearance = NSAppearance(named: .aqua)
        for (name, state) in cases {
            guard let png = StatusBarRenderer.renderPNG(state, appearance: appearance) else {
                FileHandle.standardError.write(Data("error: failed to render \(name)\n".utf8))
                exit(1)
            }
            let target = url.appendingPathComponent("\(name).png")
            do {
                try png.write(to: target)
                print("wrote \(target.path) (\(png.count) bytes)")
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        exit(0)
    }
}
