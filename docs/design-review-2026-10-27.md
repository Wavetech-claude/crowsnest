# Design review — 2026-10-27

A review of the menu bar panel against Apple's Human Interface Guidelines, using the
[`apple-design`](https://github.com/dickwu/apple-design-skill) reviewer skill (123 HIG pages,
upstream @ `914b6a3`). Citations are `page.md › Heading` in that skill's `references/hig/`.

**Scope and limits.** Code review of `Sources/` at `32ba37f`, plus the two published renders
`docs/images/panel-light.png` and `panel-dark.png`. Those come from `PreviewRender`, which draws
the real `MenuPanel` with `ImageRenderer`, so they show the shipped views, but on a flat
background: the live panel sits on the window's material, which can shift the numbers a little.
Contrast is measured from those PNGs (the strongest pixel of each glyph against the panel
background), which is the best case for anti-aliased text. **Not verified:** the app running
live, Increase Contrast, a VoiceOver pass, Full Keyboard Access.

## Summary

The panel's job is one glance: which session is waiting for me. Its signature is the menu bar
glyph, which changes **shape** rather than colour as sessions need attention — the right call for
a template image, and the thing the app is remembered by. The panel itself is a quiet, well-made
utility. **Rating: Critical issues**, because the two words the app exists to show — "Needs
approval" and "Your turn" — fail contrast in the light appearance.

## Critical

### C1 — The attention labels fail contrast in light appearance

| Text | Light | Dark | Needed |
|---|---|---|---|
| "Your turn" (`.yellow`, 10.5 pt) | `#ffcc00` on `#f7f7f7` — **1.41:1** | 11.40:1 | 4.5:1 |
| "Needs approval" (`.orange`, 10.5 pt) | `#ff8d28` on `#f7f7f7` — **2.16:1** | 7.21:1 | 4.5:1 |

`MenuPanel.swift:190-192` colours the state label with the state tint when it wants attention.
`accessibility.md › Vision`: "Up to 17 pts | All | 4.5:1".

**Fix:** keep the colour on the dot (`MenuPanel.swift:173-175`) and the menu bar glyph, and set
the label in `.primary` with `.semibold` when `wantsAttention`, `.secondary` otherwise. The dot
still says which state at a glance; the word becomes readable. No custom colours needed.

### C2 — Supporting text is below 3:1 in both appearances

Age ("12m") and the metadata line (model · tokens · branch) use `.tertiary` at 10–10.5 pt:
`#b7b7b7` on `#f7f7f7` = **1.87:1** light, `#585858` on `#212121` = **2.26:1** dark
(`MenuPanel.swift:184-198`). The repo header uses `.secondary` at 11 pt semibold: **3.90:1**
light, 5.79:1 dark (`:146-148`) — under 4.5:1, since semibold is not bold.
`accessibility.md › Vision`; `typography.md › Ensuring legibility`: "avoid light font weights… especially when text is
small".

**Fix:** `.secondary` for age and metadata, `.primary` for the repo name (its folder glyph and
count already set it apart). `.tertiary` stays fine for the decorative folder glyph.

### C3 — The refresh button is a 13 pt target with no spoken name

`MenuPanel.swift:77-85`: an 11 pt `arrow.clockwise` with `.buttonStyle(.plain)`, so the hit region
is the glyph's own frame, about 13 × 13 pt (estimated). `accessibility.md › Mobility`:
"macOS | 28x28 pt | 20x20 pt". `.help("Refresh")` is a tooltip, not an accessibility label.

**Fix:** `.frame(width: 24, height: 24).contentShape(Rectangle())` and
`.accessibilityLabel("Refresh")`.

## Improvements

- **High — An unreachable machine looks exactly like "nothing needs you."** By design the list
  never shows transport state (`SessionStore.swift:6-9`, `docs/user-guide.md` § When something's
  wrong): an SSH failure renders "No active sessions" under a moon. For an app whose whole job is
  "is anything waiting on me?", that answer is wrong when the app doesn't know.
  `feedback.md`: "Show people when a command can't be carried out and help them understand why."
  `writing.md`: "Provide clear next steps on any blank screens."
  **Trade-off:** the calm list is a deliberate choice, and error rows would spoil it. A middle
  path keeps it calm: the empty state reads "Can't reach the machine — see Settings" in the same
  quiet type, and the menu bar glyph gets a distinct shape (e.g. `bubble.left` with a slash). No
  error rows in a populated list. **Maintainer's call.**
- **High — Row actions exist only in a context menu.** Clicking a row does nothing; "Copy Resume
  Command" and "Copy Path" are reachable only by right-click (`MenuPanel.swift:212-215`), so not
  by keyboard, and not discoverable. `context-menus.md › Best practices`: "Always make context menu
  items available in the main interface, too." **Fix:** make the row a `Button` whose action
  copies the resume command, with a brief "Copied" in place of the age; keep the context menu as
  the shortcut. **Maintainer's call** on what a click should do.
- **Medium — Settings is a sheet inside the panel, with no ⌘,.** `MenuPanel.swift:49-51`.
  `settings.md › Best practices`: "people often use the standard Command-Comma (,) keyboard
  shortcut to open an app's settings". A menu-bar-only app has no app menu to hold it, but
  SwiftUI's `Settings` scene with `SettingsLink` (macOS 14) gives a standard settings window that
  survives the panel closing. Title it "Crow's Nest Settings" (`settings.md › Desktop (macOS)`: "use the title
  *App Name* Settings").
- **Medium — Fixed point sizes off the system scale.** Text is `.system(size:)` at 10, 10.5, 11,
  12, 12.5 and 13 pt. All are at or above the 10 pt macOS minimum, but 10.5 and 12.5 are
  between steps of the system scale. `typography.md › Using system fonts`: "Consider using the
  built-in text styles." On macOS, `.headline`, `.body`, `.callout`, `.caption`, `.caption2` give
  the same hierarchy with system spacing and Bold Text support.
- **Low — Remove one accessory:** the folder glyph in each repo header (`MenuPanel.swift:143`).
  The name and count already read as a group header (judgment).

## Craft notes

A deliberately quiet utility, and that is the right answer for something that lives in the menu
bar. The boldness is spent in one place: the glyph's shape change
(`CrowsNestApp.swift:52-80`), with colour inside the panel reserved for the two states that want
you. Fixing C1 moves that colour off the words and onto the dot, which keeps the rule.

## What works

- Shape, not colour, in the menu bar (`CrowsNestApp.swift:73-80`) — survives template rendering.
- Colour is never the only carrier: every dot has its state written beside it.
- `.monospacedDigit()` on ages and the badge count, so numbers don't jitter as they tick.
- Hover highlights on rows and footer buttons; tooltips carry the state's reason.
- Copied commands are shell-quoted (`MenuPanel.swift:231-233`).
- Settings' Done is the default action; the refresh interval is a picker of plain values, not a
  number field.
- A sound only for "Needs approval" (`Notifier.swift:129`) — feedback matched to significance
  (`feedback.md`).

## Platform notes

macOS 14+, `MenuBarExtra` with `.window` style. `the-menu-bar.md › Desktop (macOS) › Menu bar extras` prefers a
menu to a popover-style window "unless the app functionality you want to expose is too complex
for a menu"; grouped rows with metadata, hover and a context menu are past what a menu shows
well, so the window is justified. macOS has no Dynamic Type; text styles still pick up Bold Text.

## Proposed order

1. C1 + C2 + C3 — one change in `MenuPanel.swift`, then re-render both panel images and re-measure.
2. The two High items — after the maintainer decides what an unreachable machine and a row click
   should show.
3. Settings window, text styles.

**Preventing a repeat:** `PreviewRender` already produces both appearances from a fixture. A
check that renders them and fails when any text glyph measures under 4.5:1 against the panel
background (as measured above) would catch C1 and C2 on every UI change. It needs a Mac to run,
like `swift-tests/`.
