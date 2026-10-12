import AppKit
import GatekeeprMenuBar

/// Draws the menu bar item: the ring that drains as the session runs out (see
/// `StatusGlyph`) and the `--short` text.
///
/// MenuBarExtra shows template images in the menu bar's own colour, which is
/// right for the normal and signed-out states. The warning, expired and error
/// states need colour, so those are drawn as non-template images.
enum StatusItemImage {
    /// The ring fills the box an SF Symbol circle gets at the 13 pt menu bar
    /// font: 15 pt square, reaching 3 pt below the text baseline, so it centres
    /// on the cap height. With the baseline on a whole point, the ring's outer
    /// and inner edges fall on pixel boundaries at @1x and @2x.
    static let ringSize: CGFloat = 15
    static let belowBaseline: CGFloat = 3
    static let lineWidth: CGFloat = 2
    /// The faint full circle behind what's left of the ring.
    static let trackAlpha: CGFloat = 0.3
    static let spacing: CGFloat = 4

    static var font: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    }

    /// Where the text baseline sits above the bottom of the image: a whole
    /// point, so the text stays crisp too.
    static func baseline(for font: NSFont) -> CGFloat {
        max(belowBaseline, ceil(-font.descender))
    }

    static func make(_ state: MenuState) -> NSImage {
        let glyph = state.glyph
        let color = color(glyph.ink)
        let ink = color ?? .black
        let font = Self.font
        let text = NSAttributedString(string: state.title, attributes: [.font: font, .foregroundColor: ink])
        let textSize = text.size()

        let triangle = glyph.shape == .warningTriangle ? warningTriangle(pointSize: font.pointSize, color: ink) : nil
        let glyphWidth = triangle?.size.width ?? ringSize
        let baseline = Self.baseline(for: font)
        let size = NSSize(width: ceil(glyphWidth + spacing + textSize.width),
                          height: max(baseline - belowBaseline + ringSize, ceil(baseline + font.ascender)))
        let image = NSImage(size: size, flipped: false) { _ in
            if let triangle {
                // On the baseline, where the symbol would sit in a line of text.
                let y = (baseline - triangle.alignmentRect.minY).rounded()
                triangle.draw(in: NSRect(origin: NSPoint(x: 0, y: y), size: triangle.size))
            } else {
                let center = NSPoint(x: ringSize / 2, y: baseline - belowBaseline + ringSize / 2)
                drawRing(glyph.shape, ink: ink, center: center)
            }
            // Without .usesLineFragmentOrigin, the rect's origin is the baseline.
            text.draw(with: NSRect(x: glyphWidth + spacing, y: baseline, width: textSize.width, height: textSize.height))
            return true
        }
        image.isTemplate = color == nil
        image.accessibilityDescription = state.accessibilityLabel
        return image
    }

    /// Nil draws a template image, in the menu bar's colour.
    static func color(_ ink: StatusGlyph.Ink) -> NSColor? {
        switch ink {
        case .menuBar: return nil
        case .orange: return .systemOrange
        case .red: return .systemRed
        }
    }

    private static func drawRing(_ shape: StatusGlyph.Shape, ink: NSColor, center: NSPoint) {
        // The stroke's centre line, so its outer edge fills the box.
        let radius = (ringSize - lineWidth) / 2
        let circle = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                 width: radius * 2, height: radius * 2))
        circle.lineWidth = lineWidth
        ink.withAlphaComponent(shape == .crossedRing ? 1 : trackAlpha).setStroke()
        circle.stroke()

        ink.set()
        switch shape {
        case let .ring(fraction?) where fraction > 0:
            // What's left runs anticlockwise from 12 o'clock, so the gap grows
            // clockwise. Round caps keep the last few minutes visible as a dot.
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 + 360 * fraction, clockwise: false)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            arc.stroke()
        case .crossedRing:
            let arm: CGFloat = 2.5
            let cross = NSBezierPath()
            cross.move(to: NSPoint(x: center.x - arm, y: center.y - arm))
            cross.line(to: NSPoint(x: center.x + arm, y: center.y + arm))
            cross.move(to: NSPoint(x: center.x - arm, y: center.y + arm))
            cross.line(to: NSPoint(x: center.x + arm, y: center.y - arm))
            cross.lineWidth = 1.75
            cross.lineCapStyle = .round
            cross.stroke()
        case .dashedTrack:
            // The ring's centre is on a half point, so snap the dash to whole
            // pixels or it blurs across three rows at @1x.
            var dash = CGRect(x: center.x - 3, y: center.y - lineWidth / 2, width: 6, height: lineWidth)
            if let context = NSGraphicsContext.current?.cgContext {
                let device = context.convertToDeviceSpace(dash)
                dash = context.convertToUserSpace(CGRect(x: device.minX.rounded(), y: device.minY.rounded(),
                                                         width: device.width.rounded(), height: device.height.rounded()))
            }
            NSBezierPath(roundedRect: dash, xRadius: 0.5, yRadius: 0.5).fill()
        case .ring, .warningTriangle:
            break
        }
    }

    private static func warningTriangle(pointSize: CGFloat, color: NSColor) -> NSImage? {
        // Two layers: a white glyph on the coloured triangle.
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, color]))
        return NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }
}
