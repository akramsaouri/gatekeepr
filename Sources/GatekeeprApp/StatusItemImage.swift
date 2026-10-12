import AppKit
import GatekeeprMenuBar

/// Draws the menu bar item: a symbol and the `--short` text.
///
/// MenuBarExtra shows template images in the menu bar's own colour, which is
/// right for the normal state. The warning, expired and error states need
/// colour, so those are drawn as non-template images.
enum StatusItemImage {
    static func make(_ state: MenuState) -> NSImage {
        let style = Style(state.tone)
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        let ink = style.color ?? .black
        let text = NSAttributedString(string: state.title, attributes: [.font: font, .foregroundColor: ink])

        var configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
        if let color = style.color {
            // Filled symbols have two layers: a white glyph on the coloured shape.
            let palette = style.symbol.hasSuffix(".fill") ? [NSColor.white, color] : [color]
            configuration = configuration.applying(NSImage.SymbolConfiguration(paletteColors: palette))
        }
        let symbol = NSImage(systemSymbolName: style.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)

        let textSize = text.size()
        let symbolSize = symbol?.size ?? .zero
        let spacing: CGFloat = symbol == nil ? 0 : 4
        let size = NSSize(width: ceil(symbolSize.width + spacing + textSize.width),
                          height: ceil(max(symbolSize.height, textSize.height)))
        let image = NSImage(size: size, flipped: false) { rect in
            symbol?.draw(in: NSRect(x: 0, y: (rect.height - symbolSize.height) / 2,
                                    width: symbolSize.width, height: symbolSize.height))
            text.draw(at: NSPoint(x: symbolSize.width + spacing, y: (rect.height - textSize.height) / 2))
            return true
        }
        image.isTemplate = style.color == nil
        image.accessibilityDescription = state.accessibilityLabel
        return image
    }

    private struct Style {
        let symbol: String
        /// Nil draws a template image in the menu bar's colour.
        let color: NSColor?

        init(_ tone: MenuState.Tone) {
            switch tone {
            case .ok: (symbol, color) = ("clock", nil)
            case .warning: (symbol, color) = ("hourglass", .systemOrange)
            case .expired: (symbol, color) = ("xmark.circle.fill", .systemRed)
            case .signedOut: (symbol, color) = ("xmark.circle", nil)
            case .error: (symbol, color) = ("exclamationmark.triangle.fill", .systemRed)
            }
        }
    }
}
