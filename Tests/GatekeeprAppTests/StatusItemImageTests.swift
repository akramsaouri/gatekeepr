import AppKit
@testable import GatekeeprApp
@testable import GatekeeprMenuBar
import XCTest

final class StatusItemImageTests: XCTestCase {
    /// Every state the menu bar item can be in, as docs/menu-bar-states.png shows them.
    static let states: [(caption: String, state: MenuState)] = [
        ("100%", .sample(.ok, "24h00m", progress: 1)),
        ("75%", .sample(.ok, "18h00m", progress: 0.75)),
        ("50%", .sample(.ok, "12h00m", progress: 0.5)),
        ("25%", .sample(.ok, "6h00m", progress: 0.25)),
        ("warning", .sample(.warning, "25m", progress: 25.0 / (24 * 60))),
        ("expired", .sample(.expired, "expired", progress: 0)),
        ("signed out", .sample(.signedOut, "signed out")),
        ("error", .sample(.error, "error")),
    ]

    func testOnlyTheMonochromeStatesAreTemplates() {
        for (caption, state) in Self.states {
            let image = StatusItemImage.make(state)
            XCTAssertEqual(image.isTemplate, state.glyph.ink == .menuBar, caption)
            XCTAssertEqual(image.accessibilityDescription, state.accessibilityLabel, caption)
        }
    }

    func testTextFollowsTheRing() {
        let ring = StatusItemImage.make(.sample(.ok, "6h08m", progress: 1))
        let text = NSAttributedString(string: "6h08m", attributes: [.font: StatusItemImage.font]).size()

        XCTAssertEqual(ring.size.width, ceil(StatusItemImage.ringSize + StatusItemImage.spacing + text.width))
        XCTAssertGreaterThanOrEqual(ring.size.height, StatusItemImage.ringSize)
    }

    func testRingEdgesFallOnWholePixels() throws {
        let image = StatusItemImage.make(.sample(.ok, "24h00m", progress: 1))
        let ringBottom = StatusItemImage.baseline(for: StatusItemImage.font) - StatusItemImage.belowBaseline
        // In points from the top of the image, which is how bitmaps count rows.
        let ringTop = image.size.height - ringBottom - StatusItemImage.ringSize
        let middle = ringTop + StatusItemImage.ringSize / 2
        for scale in [1, 2] {
            let pixels = Self.render(image, scale: CGFloat(scale))
            func alpha(x: CGFloat, y: CGFloat) -> CGFloat {
                pixels.colorAt(x: Int(x * CGFloat(scale)), y: Int(y * CGFloat(scale)))?.alphaComponent ?? 0
            }
            // The left edge fills the first column; the top edge fills its row
            // and leaves the one above empty.
            XCTAssertGreaterThan(alpha(x: 0, y: middle), 0.9, "@\(scale)x left edge")
            XCTAssertGreaterThan(alpha(x: StatusItemImage.ringSize / 2, y: ringTop), 0.9, "@\(scale)x top edge")
            if ringTop >= 1 {
                XCTAssertLessThan(alpha(x: StatusItemImage.ringSize / 2, y: ringTop - 1 / CGFloat(scale)), 0.05, "@\(scale)x above")
            }
        }
    }

    /// Draws every state on light and dark menu bars, at @2x and at @1x with its
    /// pixels doubled. To update docs/menu-bar-states.png:
    ///
    ///     GATEKEEPR_STATUS_STRIP=docs/menu-bar-states.png swift test --filter StatusItemImageTests
    func testStatesStrip() throws {
        let png = try XCTUnwrap(Self.strip().representation(using: .png, properties: [:]))
        guard let path = ProcessInfo.processInfo.environment["GATEKEEPR_STATUS_STRIP"] else { return }
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try png.write(to: URL(fileURLWithPath: path, relativeTo: packageRoot))
    }

    // MARK: Helpers

    static func strip() -> NSBitmapImageRep {
        let rows: [(label: String, dark: Bool, scale: CGFloat)] = [
            ("Light, @2x", false, 2), ("Dark, @2x", true, 2),
            ("Light, @1x ×2", false, 1), ("Dark, @1x ×2", true, 1),
        ]
        let labelWidth: CGFloat = 100, column: CGFloat = 112, rowHeight: CGFloat = 26, gap: CGFloat = 4, captionHeight: CGFloat = 24
        let size = NSSize(width: labelWidth + column * CGFloat(states.count),
                          height: captionHeight + (rowHeight + gap) * CGFloat(rows.count))
        let small = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 11),
                     .foregroundColor: NSColor(white: 0.43, alpha: 1)]
        let canvas = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            for (index, item) in states.enumerated() {
                NSAttributedString(string: item.caption, attributes: small)
                    .draw(at: NSPoint(x: labelWidth + column * CGFloat(index), y: size.height - captionHeight + 6))
            }
            for (number, row) in rows.enumerated() {
                let bottom = size.height - captionHeight - (rowHeight + gap) * CGFloat(number + 1) + gap
                NSAttributedString(string: row.label, attributes: small).draw(at: NSPoint(x: 10, y: bottom + 6))
                (row.dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                NSRect(x: labelWidth - 10, y: bottom, width: size.width - labelWidth + 10, height: rowHeight).fill()
                for (index, item) in states.enumerated() {
                    let image = onMenuBar(StatusItemImage.make(item.state), dark: row.dark)
                    let frame = NSRect(x: labelWidth + column * CGFloat(index),
                                       y: bottom + ((rowHeight - image.size.height) / 2).rounded(),
                                       width: image.size.width, height: image.size.height)
                    if row.scale == 1 {
                        // Drawn at @1x, then each pixel shown as 2 × 2.
                        NSGraphicsContext.current?.imageInterpolation = .none
                        render(image, scale: 1).draw(in: frame, from: .zero, operation: .sourceOver,
                                                     fraction: 1, respectFlipped: false, hints: nil)
                    } else {
                        image.draw(in: frame)
                    }
                }
            }
            return true
        }
        return render(canvas, scale: 2)
    }

    /// What the menu bar does with a template image: draws it in its own text colour.
    static func onMenuBar(_ image: NSImage, dark: Bool) -> NSImage {
        guard image.isTemplate else { return image }
        return NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            (dark ? NSColor(white: 1, alpha: 0.9) : NSColor(white: 0, alpha: 0.85)).set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    static func render(_ image: NSImage, scale: CGFloat) -> NSBitmapImageRep {
        let pixels = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale), pixelsHigh: Int(image.size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        pixels.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: pixels)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return pixels
    }
}

extension MenuState {
    static func sample(_ tone: Tone, _ title: String, progress: Double? = nil) -> MenuState {
        MenuState(tone: tone, title: title, accessibilityLabel: "Gatekeepr: \(title)", heading: title,
                  details: [], history: [], progress: progress)
    }
}
