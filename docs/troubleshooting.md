# Troubleshooting

The session list never shows errors on purpose, so start every diagnosis here:

```bash
cat ~/.claude-fleet/last-poll.log
```

and **Settings → Diagnostics** in the app. That one line is usually the whole answer.

---

## The list is empty and I expected remote sessions

Work through these in order — the first is by far the most common.

### 1. macOS Local Network permission

`last-poll.log` shows `No route to host`, but you can `ssh <host>` fine from a terminal.

The app needs a **Local Network** grant to reach the LAN, and the prompt is easy to miss
or may not appear at all (see [traps §4](traps.md#4-the-macos-local-network-permission-deadlock)).

- Check **System Settings → Privacy & Security → Local Network** for "Claude Fleet" and
  turn it **on**.
- If it isn't listed, quit and relaunch the app so it re-attempts a connection (that's what
  registers it). Then check again.

### 2. The SSH host isn't trusted yet

`last-poll.log` shows `Host key verification failed` or a prompt-related error.

The app runs SSH non-interactively and does **not** auto-accept unknown host keys (a
deliberate security choice). Trust the host once from a terminal:

```bash
ssh <alias> echo ok      # accept the fingerprint when asked
```

Then it works from the app.

### 3. The alias doesn't connect non-interactively

```bash
ssh -o BatchMode=yes <alias> echo ok
```

If that doesn't print `ok`, the app can't connect either. Fix the SSH setup first —
usually a missing key or an agent-only key. The app cannot use a key that requires an
interactive passphrase each time.

### 4. No Python on the remote

`last-poll.log` shows something like `produced no usable output`.

The collector needs *some* Python on the remote. On Windows, `python`/`python3` are Store
stubs — install real Python so `py` works, or install Python for All Users. The app probes
`python3`, `py`, and `python`; if none is real, it can't collect.

---

## The list is empty and I have no remote configured

Check **Include this Mac** is on in Settings, and that you actually have Claude Code
sessions running locally (`ls ~/.claude/sessions/`). An empty list with no sessions
anywhere is the correct, calm state.

---

## The menu bar icon is there but clicking shows nothing

You're on an old build. This was a bug where the panel's scroll view collapsed to zero
height inside the menu bar window. Rebuild:

```bash
./build.sh && open ~/Applications/ClaudeFleet.app
```

---

## Notifications don't arrive

- Confirm you allowed them: **System Settings → Notifications → Claude Fleet**.
- The app only notifies on the *transition into* a state, and never for sessions already in
  that state when it launched. To test, take a running session from working into a
  permission prompt and wait one refresh interval.

---

## Notifications arrive with a blank/missing icon

You're on a build from before the app had an icon. Rebuild with the current `build.sh`,
which bundles `AppIcon.icns`.

---

## A session I know is running isn't shown

Check **Settings → Diagnostics** for a "hidden" entry naming it — the app records why it
hid anything. A confirmed-dead process (the pid is genuinely gone) is hidden on purpose. If
it's hidden but you believe it's alive, that's a bug worth reporting, with the diagnostics
line attached.

---

## Everything suddenly reads as one state, or nothing appears

The likely cause is a **Claude Code update that changed the on-disk format** the collector
reads (it's not a public API). Note your `claude --version`, attach `last-poll.log`, and
open an issue — this is the failure mode the project expects over time.
