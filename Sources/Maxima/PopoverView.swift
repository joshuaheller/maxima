import SwiftUI
import AppKit

/// Dropdown content shown from the status item, styled after the claude.ai usage panel.
struct PopoverView: View {
    let model: UsageModel
    var height: CGFloat = 480

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = model.lastError {
                        errorBanner(error.userMessage)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Claude").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                        section(for: model.snapshot?.allModels, fallbackTitle: "All models")
                        section(for: model.snapshot?.fable, fallbackTitle: "Fable")
                        section(for: model.snapshot?.session, fallbackTitle: "Current session")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 16)

                    Divider()
                    if let error = model.codexError { errorBanner(error) }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Codex").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                        section(for: model.codexSnapshot?.session, fallbackTitle: "Codex · 5 hours",
                                unavailableText: model.codexSnapshot != nil ? "Not provided by Codex for this account" : nil)
                        section(for: model.codexSnapshot?.weekly, fallbackTitle: "Codex · Weekly")
                        if let updated = model.codexUpdated {
                            (Text("Updated ") + Text(updated, style: .relative))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 320, height: height)
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
        .padding(.bottom, 10)
    }

    // MARK: Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
            Text(message)
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
    private func section(for limit: UsageLimit?, fallbackTitle: String, unavailableText: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(limit?.kind.displayName ?? fallbackTitle)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(limit.map { "\($0.percent)%" } ?? "–")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if limit != nil {
                ProgressBar(fraction: limit?.fraction ?? 0, tint: tint(limit?.severity ?? .normal))
            }
            Text(limit == nil ? (unavailableText ?? "No data yet") : resetText(limit))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        .frame(height: 7)
    }
}
