import AppKit
import SwiftUI
import Observation
import os

/// Owns the `NSStatusItem`, keeps its image in sync with the model, and manages
/// the popover.
@MainActor
final class StatusItemController: NSObject {
    private let model: UsageModel
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let log = Logger(subsystem: AppInfo.subsystem, category: "statusitem")

    private var appearanceObservation: NSKeyValueObservation?
    private var globalMouseMonitor: Any?
    private var renderedState: StatusDisplayState?

    init(model: UsageModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model))
        self.popover = popover

        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageOnly
            button.toolTip = AppInfo.displayName

            // Non-template images do not follow light/dark automatically, so a
            // change of appearance has to force a re-render.
            appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.render(force: true)
                }
            }
        }

        observeModel()
        render(force: true)
    }

    deinit {
        appearanceObservation?.invalidate()
    }

    // MARK: Observation

    /// `withObservationTracking` is one-shot, so it re-arms itself after each change.
    private func observeModel() {
        withObservationTracking {
            _ = model.snapshot
            _ = model.lastError
            _ = model.lastUpdated
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.render()
                self.observeModel()
            }
        }
    }

    // MARK: Rendering

    private func render(force: Bool = false) {
        let state = model.displayState
        guard force || state != renderedState else { return }
        renderedState = state

        guard let button = statusItem.button else { return }
        let image = StatusBarRenderer.render(state, appearance: button.effectiveAppearance)
        button.image = image
        button.appearsDisabled = state.isStale
        button.toolTip = tooltip(for: state)
    }

    private func tooltip(for state: StatusDisplayState) -> String {
        var lines = ["\(AppInfo.displayName)"]
        if let all = state.all { lines.append("All models (weekly): \(all.percent)%") }
        if let fable = state.fable { lines.append("Fable (weekly): \(fable.percent)%") }
        if let session = model.snapshot?.session { lines.append("Session: \(session.percent)%") }
        if let error = model.lastError { lines.append(error.userMessage) }
        return lines.joined(separator: "\n")
    }

    // MARK: Popover

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        // An .accessory app is not active, and an inactive app's popover renders
        // (and dismisses) unreliably — activate first.
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        // Transient dismissal alone does not reliably fire for a menu-bar-only
        // app, so watch for clicks in every other app too.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closePopover()
            }
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
    }
}
