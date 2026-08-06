import SwiftUI
import AppKit

/// Dropdown content shown from the status item, styled after the claude.ai usage panel.
struct PopoverView: View {
    let model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let error = model.lastError {
                errorBanner(error)
            }

            VStack(alignment: .leading, spacing: 18) {
                section(for: model.snapshot?.allModels, fallbackTitle: "All models")
                section(for: model.snapshot?.fable, fallbackTitle: "Fable")
                section(for: model.snapshot?.session, fallbackTitle: "Current session")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 16)

            Divider()
            footer
        }
        .frame(width: 300)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Usage")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }

    // MARK: Error banner

    private func errorBanner(_ error: UsageError) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
            Text(error.userMessage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    // MARK: Sections

    @ViewBuilder
    private func section(for limit: UsageLimit?, fallbackTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(limit?.kind.displayName ?? fallbackTitle)
                .font(.system(size: 12, weight: .semibold))

            Text(resetText(limit))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            ProgressBar(fraction: limit?.fraction ?? 0, tint: tint(limit?.severity ?? .normal))

            Text(limit.map { "\($0.percent)% used" } ?? "No data")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func resetText(_ limit: UsageLimit?) -> String {
        guard let resetsAt = limit?.resetsAt else { return "Reset time unknown" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = .current
        let zone = TimeZone.current.abbreviation() ?? TimeZone.current.identifier
        return "Resets \(formatter.string(from: resetsAt)) \(zone)"
    }

    private func tint(_ severity: Severity) -> Color {
        switch severity {
        case .normal: return .accentColor
        case .warning: return .orange
        case .critical: return .red
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let lastUpdated = model.lastUpdated {
                // `.relative` re-renders itself, so the footer stays honest.
                Text("Updated ") + Text(lastUpdated, style: .relative)
            } else {
                Text("Never updated")
            }
            Spacer()
            Button("Refresh now") { model.refresh(reason: "manual") }
                .disabled(model.isRefreshing)
            Button("Quit") { NSApp.terminate(nil) }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .buttonStyle(.link)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Capsule progress bar used inside the popover.
private struct ProgressBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, fraction)) * geometry.size.width)
            }
        }
        .frame(height: 10)
    }
}
