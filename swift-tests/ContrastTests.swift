import AppKit

/// Holds every pairing of text colour and surface the panel draws to WCAG
/// contrast, in light, dark, and both Increase Contrast appearances: 4.5:1 for
/// text (everything in the panel is under 18 pt), 3:1 for the glyph inside a
/// state disc (a graphic, and the state is also written in words).
///
/// The pairings come from `Palette.swift`, which is the only place the panel
/// takes colours from; `run.sh` refuses system styles in `MenuPanel.swift`, so a
/// colour can't reach the panel without passing through here. Compiled by
/// `run.sh` with just `Palette.swift` and `Session.swift`.
@main
struct ContrastTests {
    struct RGBA { var r, g, b, a: Double }

    static func main() {
        var failures: [String] = []
        let appearances: [(String, NSAppearance.Name)] = [
            ("light", .aqua), ("dark", .darkAqua),
            ("light, increased contrast", .accessibilityHighContrastAqua),
            ("dark, increased contrast", .accessibilityHighContrastDarkAqua),
        ]

        for (name, appearanceName) in appearances {
            guard let appearance = NSAppearance(named: appearanceName) else {
                failures.append("\(name): appearance unavailable")
                continue
            }
            func rgba(_ color: NSColor) -> RGBA {
                var out = RGBA(r: 0, g: 0, b: 0, a: 0)
                appearance.performAsCurrentDrawingAppearance {
                    let c = color.usingColorSpace(.sRGB)!
                    out = RGBA(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
                }
                return out
            }

            let panel = rgba(Palette.panel)
            let text = rgba(Palette.text)
            let secondary = rgba(Palette.secondaryText)
            let tile = over(faded(text, Palette.tileFill), panel)
            let tileHover = over(faded(text, Palette.tileFill * 2), panel)

            var surfaces: [(String, RGBA)] = [("panel", panel), ("tile", tile), ("tile, hovered", tileHover)]
            for state in Session.State.allCases where state.wantsAttention {
                let tint = rgba(Palette.tint(state))
                surfaces.append(("\(state.label) card, strong end", over(faded(tint, Palette.cardTintStrong), panel)))
                surfaces.append(("\(state.label) card, weak end", over(faded(tint, Palette.cardTintWeak), panel)))
            }

            for (surfaceName, surface) in surfaces {
                for (textName, color) in [("text", text), ("secondary text", secondary)] {
                    let ratio = contrast(over(color, surface), surface)
                    report(&failures, "\(name): \(textName) on \(surfaceName)", ratio, needed: 4.5)
                }
            }

            for state in Session.State.allCases {
                if Palette.isBright(state) {
                    let disc = rgba(Palette.tint(state))
                    let glyph = over(rgba(Palette.glyphOnTint), disc)
                    report(&failures, "\(name): glyph on \(state.label) disc", contrast(glyph, disc), needed: 3)
                } else {
                    let disc = over(faded(text, Palette.quietDiscFill), tile)
                    report(&failures, "\(name): glyph on \(state.label) disc", contrast(over(secondary, disc), disc), needed: 3)
                }
            }
        }

        if failures.isEmpty {
            print("All contrast checks passed.")
            exit(0)
        }
        print("\(failures.count) contrast check(s) failed:")
        failures.forEach { print("  - \($0)") }
        exit(1)
    }

    static func report(_ failures: inout [String], _ name: String, _ ratio: Double, needed: Double) {
        let line = "\(name): \(String(format: "%.2f", ratio)):1 (needs \(String(format: "%.1f", needed)))"
        if ratio >= needed {
            print("ok   - \(line)")
        } else {
            failures.append(line)
            print("FAIL - \(line)")
        }
    }

    static func faded(_ c: RGBA, _ opacity: Double) -> RGBA {
        RGBA(r: c.r, g: c.g, b: c.b, a: c.a * opacity)
    }

    /// `top` painted over an opaque `bottom`.
    static func over(_ top: RGBA, _ bottom: RGBA) -> RGBA {
        func mix(_ t: Double, _ b: Double) -> Double { t * top.a + b * (1 - top.a) }
        return RGBA(r: mix(top.r, bottom.r), g: mix(top.g, bottom.g), b: mix(top.b, bottom.b), a: 1)
    }

    /// WCAG 2 relative luminance and contrast ratio.
    static func luminance(_ c: RGBA) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    static func contrast(_ a: RGBA, _ b: RGBA) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
