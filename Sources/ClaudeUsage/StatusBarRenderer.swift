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
    /// Top bar: weekly "All models".
    public var all: BarState?
    /// Bottom bar: weekly "Fable".
    public var fable: BarState?
    /// Data is stale/errored — dim the item and show a warning glyph.
    public var isStale: Bool

    public init(all: BarState?, fable: BarState?, isStale: Bool) {
        self.all = all
        self.fable = fable
        self.isStale = isStale
    }

    /// Monochrome template rendering is only correct while nothing needs colour.
    public var isTemplateEligible: Bool {
        !isStale && [all, fable].compactMap { $0?.severity }.allSatisfy { $0 == .normal }
    }
}

/// Draws the two stacked mini progress bars shown in the menu bar.
///
/// Pure: same input, same image. No global state, so it is unit-testable and
/// usable from the `--render-test` CLI path.
public enum StatusBarRenderer {
    public static let height: CGFloat = 22
    public static let baseWidth: CGFloat = 64
    /// Extra room for the stale warning triangle.
    public static let staleWidth: CGFloat = 74

    private static let barHeight: CGFloat = 7
    private static let barGap: CGFloat = 2
    private static let cornerRadius: CGFloat = 2
    private static let textWidth: CGFloat = 24
    private static let textGap: CGFloat = 3
    private static let glyphWidth: CGFloat = 10

    public static func width(isStale: Bool) -> CGFloat { isStale ? staleWidth : baseWidth }

    /// Renders the status item image.
    /// - Parameter appearance: appearance used to resolve dynamic system colours.
    ///   Ignored when the result is a template image (which the system tints itself).
    public static func render(_ state: StatusDisplayState, appearance: NSAppearance? = nil) -> NSImage {
        let isTemplate = state.isTemplateEligible
        let size = NSSize(width: width(isStale: state.isStale), height: height)

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

        let glyphSpace: CGFloat = state.isStale ? glyphWidth : 0
        let barWidth = size.width - textWidth - textGap - glyphSpace
        let stackHeight = barHeight * 2 + barGap
        let bottomY = ((size.height - stackHeight) / 2).rounded()

        drawRow(state.fable, y: bottomY, barWidth: barWidth,
                neutral: neutral, secondary: secondary, isTemplate: isTemplate, size: size)
        drawRow(state.all, y: bottomY + barHeight + barGap, barWidth: barWidth,
                neutral: neutral, secondary: secondary, isTemplate: isTemplate, size: size)

        if state.isStale {
            drawStaleGlyph(size: size, color: secondary)
        }
    }

    private static func drawRow(_ bar: BarState?, y: CGFloat, barWidth: CGFloat,
                                neutral: NSColor, secondary: NSColor,
                                isTemplate: Bool, size: NSSize) {
        let trackRect = NSRect(x: 0, y: y, width: barWidth, height: barHeight)
        neutral.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()

        guard let bar else { return }

        let fillWidth = (barWidth * bar.fraction).rounded()
        if fillWidth >= 1 {
            let fillRect = NSRect(x: 0, y: y, width: max(fillWidth, cornerRadius * 2), height: barHeight)
            fillColor(for: bar.severity, neutral: neutral, isTemplate: isTemplate).setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        }

        let text = "\(bar.percent)%" as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: isTemplate ? NSColor.black : neutral,
            .paragraphStyle: paragraph,
        ]
        let textRect = NSRect(
            x: barWidth + textGap,
            y: y + (barHeight - font.capHeight) / 2 - (font.ascender - font.capHeight) - 0.5,
            width: textWidth,
            height: font.ascender - font.descender
        )
        text.draw(in: textRect, withAttributes: attributes)
    }

    private static func fillColor(for severity: Severity, neutral: NSColor, isTemplate: Bool) -> NSColor {
        guard !isTemplate else { return neutral }
        switch severity {
        case .normal: return neutral
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
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
