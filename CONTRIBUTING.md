# Contributing

Thanks for looking. A few honest notes so you know what you're walking into.

## The bar

There are two test suites and both must stay green:

```bash
python3 -m unittest discover -s tests -t tests   # collector.py logic — 18 checks
./swift-tests/run.sh                              # Notifier state machine + security, then panel contrast
```

**Every colour in the panel comes from `Sources/Palette.swift`.** `swift-tests/ContrastTests.swift`
holds each text colour on each surface to 4.5:1 (and each state glyph to 3:1) in light, dark
and both Increase Contrast appearances, and `run.sh` fails if `MenuPanel.swift` uses
`.secondary`, `.tertiary` or a raw system colour, because the check cannot see those. A new
colour goes into `Palette` and into the check, or it doesn't go in.

CI runs both suites and `build.sh` on every pull request (`.github/workflows/ci.yml`, job
`checks`), and `main` only accepts a change whose `checks` passed.

The Swift app has no XCTest target on purpose (there's no SwiftPM package here); the
testable logic — the notifier's decision machine and the input-sanitisation — is
exercised by `swift-tests/` as a plain compiled executable. If you change either,
add a check there. The `Notifier` in particular earned its tests: it needed several
corrections during development, every one found by review rather than by a test, which
is exactly why the tests now exist.

For UI changes, render the offline preview and look at it:

```bash
swiftc -O -parse-as-library -DPREVIEW -target arm64-apple-macos14.0 \
    -o /tmp/cfpreview Sources/*.swift && /tmp/cfpreview fixtures/blocked.json /tmp/p.png dark
```

## Two rules that are load-bearing, not style

1. **The main session list never shows transport state.** No hostnames, no connection
   status, no error text, no "unreachable" rows. Diagnostics live only in Settings and
   `last-poll.log`. A PR that surfaces an error in the list will be declined — that
   noise is the exact thing this app was built to remove.

2. **Absence of information is not information.** A process that isn't in the table, a
   session that wasn't in the last poll, a field that didn't decode — none of those
   mean "it's gone" or "it's new". This bit us three separate times (liveness, the
   notifier, the payload decode). Treat missing data as *unknown* and fail toward
   showing the session, never toward hiding it.

## What's unlikely to be merged

- **Support for a platform I can't test.** If you add Linux-remote or a different SSH
  topology, I can't verify it doesn't regress, so I probably won't take on maintaining
  it. Keep it in your fork, or expect it to be marked unsupported.
- **New runtime dependencies.** The collector is stdlib-only and piped over SSH so the
  remote needs nothing installed; the app has no third-party packages. Both are
  features, not accidents.

## Testing a *cold* remote connection

If your change touches the SSH path, know this trap: SSH holds a shared master socket
open for 5 minutes (`ControlPersist=300`), so a test run shortly after any other SSH to
the same host silently succeeds by reusing it and proves nothing. Before testing a cold
connection, always:

```bash
ssh -O exit <host> 2>/dev/null; rm -f ~/.crowsnest/cm/*
```

This is written up in [docs/traps.md](docs/traps.md) — it cost real hours.
