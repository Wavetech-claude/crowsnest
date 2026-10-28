import AppKit
import SwiftUI

/// Every colour the panel draws text in, and every surface it draws text on, in
/// one place, so `swift-tests/ContrastTests.swift` can hold each pairing to
/// WCAG contrast in both appearances. The panel uses nothing else:
/// `swift-tests/run.sh` refuses `.secondary`, `.tertiary` and raw system tints
/// in `MenuPanel.swift`, because a colour that isn't here is a colour nobody
/// measured.
enum Palette {
    /// The panel's background, as `PreviewRender` draws it. The live panel sits on
    /// the window's material, which can shift the numbers a little.
    static let panel = dynamic(light: NSColor(white: 0.97, alpha: 1),
                               dark: NSColor(white: 0.13, alpha: 1))

    /// Headline text: titles and the state words.
    static let text = NSColor.labelColor

    /// Supporting text: age, place, percentages, the footer. Not
    /// `secondaryLabelColor`, which measures about 3.9:1 on the light panel,
    /// under the 4.5:1 that text this small needs.
    static let secondaryText = dynamic(light: NSColor(white: 0, alpha: 0.66),
                                       dark: NSColor(white: 1, alpha: 0.70))

    /// The glyph inside a bright state disc. Near-black on every bright tint, in
    /// both appearances: white on the system yellow would be about 1.5:1.
    static let glyphOnTint = NSColor(white: 0, alpha: 0.8)

    /// An attention card's tint, at the gradient's strong and weak ends.
    static let cardTintStrong: CGFloat = 0.28
    static let cardTintWeak: CGFloat = 0.10

    /// A calm tile, and the disc of an idle or unknown session: `text` at this
    /// opacity over the panel.
    static let tileFill: CGFloat = 0.05
    static let quietDiscFill: CGFloat = 0.10

    /// Context use at or past this percentage turns the bar red: the session is
    /// close to needing a fresh start.
    static let contextWarnPercent = 85

    static func tint(_ state: Session.State) -> NSColor {
        switch state {
        case .blocked: .systemOrange
        case .waiting: .systemYellow
        case .working: .systemGreen
        case .idle, .unknown: .secondaryLabelColor
        }
    }

    /// Bright states get a filled disc in their tint; quiet ones a neutral disc.
    static func isBright(_ state: Session.State) -> Bool {
        state == .blocked || state == .waiting || state == .working
    }

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

extension Color {
    static let panelText = Color(nsColor: Palette.text)
    static let panelSecondary = Color(nsColor: Palette.secondaryText)
    static func stateTint(_ state: Session.State) -> Color { Color(nsColor: Palette.tint(state)) }
}
