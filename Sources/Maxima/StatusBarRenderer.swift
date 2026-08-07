import AppKit

/// One drawn bar: a percentage and the severity that colours it.
public struct BarState: Sendable, Equatable {
    public var percent: Int
    public var severity: Severity

    public init(percent: Int, severity: Severity) {
        self.percent = percent
        self.severity = severity
    }

    public var fraction: Double { Double(min(max(percent, 0), 100)) / 100.0 }
}

/// Everything the status item needs to draw itself. Deliberately decoupled from
/// the model so rendering stays a pure function of this value.
public struct StatusDisplayState: Sendable, Equatable {
    /// Top weekly bar: "All models".
    public var all: BarState?
    /// Bottom weekly bar: "Fable".
    public var fable: BarState?
    /// The current 5-hour session, drawn as a vertical green→red gauge.
    public var session: BarState?
    /// Pre-formatted "time left" until the session resets (e.g. "3h05m"). The model
    /// cannot compute this — it is wall-clock dependent — so the controller fills it
    /// in and re-renders once a minute.
    public var sessionCountdown: String?
    /// Data is stale/errored — dim the item and show a warning glyph.
    public var isStale: Bool

    public init(all: BarState?, fable: BarState?,
                session: BarState? = nil, sessionCountdown: String? = nil,
                isStale: Bool) {
        self.all = all
        self.fable = fable
        self.session = session
        self.sessionCountdown = sessionCountdown
        self.isStale = isStale
    }

    /// Monochrome template rendering is only correct while nothing needs colour. The
    /// session gauge is always coloured (green→red), so its presence rules it out.
    public var isTemplateEligible: Bool {
        session == nil && !isStale && [all, fable].compactMap { $0?.severity }.allSatisfy { $0 == .normal }
    }
}

/// Draws the menu bar status item: a leading Claude glyph, two stacked weekly
/// progress bars, and — for the current session — a vertical green→red gauge with
/// a countdown to its reset.
///
/// Pure: same input, same image. No global state, so it is unit-testable and
/// usable from the `--render-test` CLI path.
public enum StatusBarRenderer {
    public static let height: CGFloat = 22

    // Weekly stacked bars.
    private static let barHeight: CGFloat = 7
    private static let barGap: CGFloat = 2
    private static let cornerRadius: CGFloat = 2
    private static let weeklyBarWidth: CGFloat = 26
    /// Wide enough for "100%" at `percentFont` — a narrower column clips the "%".
    static let textWidth: CGFloat = 28
    private static let textGap: CGFloat = 3

    // Leading Claude glyph.
    private static let iconWidth: CGFloat = 13
    private static let iconGap: CGFloat = 5

    // Trailing session column.
    private static let sessionBarWidth: CGFloat = 5
    private static let sessionGap: CGFloat = 6
    private static let timerGap: CGFloat = 4

    /// Extra room for the stale warning triangle.
    private static let glyphWidth: CGFloat = 10
    private static let edgePadding: CGFloat = 2

    static var percentFont: NSFont { .monospacedDigitSystemFont(ofSize: 9, weight: .medium) }
    static var timerFont: NSFont { .monospacedDigitSystemFont(ofSize: 9, weight: .medium) }

    /// The item is variable width; it grows for the session column, the countdown
    /// text, and the stale glyph.
    public static func width(for state: StatusDisplayState) -> CGFloat {
        var width = edgePadding + iconWidth + iconGap + weeklyBarWidth + textGap + textWidth
        if state.session != nil {
            width += sessionGap + sessionBarWidth
            if let countdown = state.sessionCountdown, !countdown.isEmpty {
                width += timerGap + measure(countdown, font: timerFont).rounded(.up)
            }
        }
        if state.isStale { width += glyphWidth }
        return width + edgePadding
    }

    private static func measure(_ string: String, font: NSFont) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: font]).width
    }

    /// Renders the status item image.
    /// - Parameter appearance: appearance used to resolve dynamic system colours.
    ///   Ignored when the result is a template image (which the system tints itself).
    public static func render(_ state: StatusDisplayState, appearance: NSAppearance? = nil) -> NSImage {
        let isTemplate = state.isTemplateEligible
        let size = NSSize(width: width(for: state), height: height)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2),
            pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: size)
        }
        rep.size = size

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high

        let draw = { drawContents(state, isTemplate: isTemplate, size: size) }
        if isTemplate {
            draw()
        } else if let appearance {
            appearance.performAsCurrentDrawingAppearance(draw)
        } else {
            draw()
        }

        NSGraphicsContext.current = previous

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = isTemplate
        return image
    }

    /// PNG bytes for the same rendering — used by `--render-test`.
    public static func renderPNG(_ state: StatusDisplayState, appearance: NSAppearance? = nil) -> Data? {
        let image = render(state, appearance: appearance)
        guard let rep = image.representations.first as? NSBitmapImageRep else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Drawing

    private static func drawContents(_ state: StatusDisplayState, isTemplate: Bool, size: NSSize) {
        let neutral: NSColor = isTemplate ? .black : .labelColor
        let secondary: NSColor = isTemplate ? .black : .secondaryLabelColor

        var x = edgePadding

        // 1) Leading Claude glyph.
        drawClaudeGlyph(in: NSRect(x: x, y: (size.height - iconWidth) / 2, width: iconWidth, height: iconWidth),
                        color: neutral)
        x += iconWidth + iconGap

        // 2) Two stacked weekly bars with their percentages.
        let stackHeight = barHeight * 2 + barGap
        let bottomY = ((size.height - stackHeight) / 2).rounded()
        drawRow(state.fable, x: x, y: bottomY,
                neutral: neutral, secondary: secondary, isTemplate: isTemplate)
        drawRow(state.all, x: x, y: bottomY + barHeight + barGap,
                neutral: neutral, secondary: secondary, isTemplate: isTemplate)
        x += weeklyBarWidth + textGap + textWidth

        // 3) Trailing session column: a vertical green→red gauge and a countdown.
        if let session = state.session {
            x += sessionGap
            let inset: CGFloat = 4
            drawSessionGauge(session,
                             in: NSRect(x: x, y: inset, width: sessionBarWidth, height: size.height - inset * 2),
                             neutral: neutral)
            x += sessionBarWidth
            if let countdown = state.sessionCountdown, !countdown.isEmpty {
                x += timerGap
                drawTimer(countdown, x: x, height: size.height, color: secondary)
            }
        }

        // 4) Stale warning glyph, far right.
        if state.isStale {
            drawStaleGlyph(size: size, color: secondary)
        }
    }

    private static func drawRow(_ bar: BarState?, x: CGFloat, y: CGFloat,
                                neutral: NSColor, secondary: NSColor, isTemplate: Bool) {
        let trackRect = NSRect(x: x, y: y, width: weeklyBarWidth, height: barHeight)
        neutral.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()

        guard let bar else { return }

        let fillWidth = (weeklyBarWidth * bar.fraction).rounded()
        if fillWidth >= 1 {
            let fillRect = NSRect(x: x, y: y, width: max(fillWidth, cornerRadius * 2), height: barHeight)
            fillColor(for: bar.severity, neutral: neutral, isTemplate: isTemplate).setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        }

        let text = "\(bar.percent)%" as NSString
        let font = percentFont
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: isTemplate ? NSColor.black : neutral,
            .paragraphStyle: paragraph,
        ]
        let textRect = NSRect(
            x: x + weeklyBarWidth + textGap,
            y: y + (barHeight - font.capHeight) / 2 - (font.ascender - font.capHeight) - 0.5,
            width: textWidth,
            height: font.ascender - font.descender
        )
        text.draw(in: textRect, withAttributes: attributes)
    }

    /// Vertical session gauge, filled from the bottom. Its colour rides a continuous
    /// green→red hue by load (not the discrete severity buckets the weekly bars use),
    /// so it reads at a glance without a number.
    private static func drawSessionGauge(_ bar: BarState, in rect: NSRect, neutral: NSColor) {
        let radius = rect.width / 2
        neutral.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        let fillHeight = (rect.height * CGFloat(bar.fraction)).rounded()
        guard fillHeight >= 1 else { return }
        let fillRect = NSRect(x: rect.minX, y: rect.minY,
                              width: rect.width, height: max(fillHeight, rect.width))
        sessionColor(fraction: bar.fraction).setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
    }

    /// Continuous green (low) → red (high). Deliberately not the traffic-light
    /// severity buckets: a smooth hue sweep so the exact load reads without a number.
    static func sessionColor(fraction: Double) -> NSColor {
        let f = CGFloat(min(max(fraction, 0), 1))
        let hue = 0.34 * (1 - f)   // 0.34 (green) → 0.0 (red)
        return NSColor(hue: hue, saturation: 0.85, brightness: 0.92, alpha: 1)
    }

    private static func drawTimer(_ text: String, x: CGFloat, height: CGFloat, color: NSColor) {
        let font = timerFont
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let string = text as NSString
        let textSize = string.size(withAttributes: attributes)
        string.draw(in: NSRect(x: x, y: (height - textSize.height) / 2, width: textSize.width, height: textSize.height),
                    withAttributes: attributes)
    }

    private static func fillColor(for severity: Severity, neutral: NSColor, isTemplate: Bool) -> NSColor {
        guard !isTemplate else { return neutral }
        switch severity {
        case .normal: return neutral
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }

    /// A small radiating sunburst that reads as "Claude" at a glance. Deliberately a
    /// generic burst, not the exact wordmark — Maxima is not affiliated with Anthropic.
    private static func drawClaudeGlyph(in rect: NSRect, color: NSColor) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let spokes = 12
        let inner = rect.width * 0.12
        let outer = rect.width * 0.48

        let path = NSBezierPath()
        path.lineWidth = max(1, rect.width * 0.10)
        path.lineCapStyle = .round
        for i in 0..<spokes {
            let angle = CGFloat(i) / CGFloat(spokes) * 2 * .pi
            path.move(to: NSPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
            path.line(to: NSPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
        }
        color.setStroke()
        path.stroke()
    }

    private static func drawStaleGlyph(size: NSSize, color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                   accessibilityDescription: "Usage data is stale")?
            .withSymbolConfiguration(config) else { return }

        let side: CGFloat = 9
        let rect = NSRect(x: size.width - side, y: (size.height - side) / 2, width: side, height: side)
        symbol.isTemplate = true
        symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        color.setFill()
        rect.fill(using: .sourceAtop)
    }
}
