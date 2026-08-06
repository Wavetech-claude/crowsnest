# Traps

The gotchas that made this app more work than it looks. Each one is written up because
it cost real time and would cost the next person the same.

## 1. On Windows, `python` and `python3` are impostors

Windows 11 ships "App execution aliases" for `python` and `python3` that are **not
Python**. They print a message telling you to install it from the Microsoft Store and
exit — with code **49** and, critically, **empty stdout**. The only command that runs
real Python is `py`.

So the collector can't assume `python3`. The app probes `python3`, then `py`, then
`python`, per host, and caches the winner. The empty-stdout-on-failure behaviour is what
makes the probe clean: a run only "counts" if its output contains the `<<<CROWSNEST>>>`
marker, so a stub that produced nothing falls through to the next candidate. Had the stub
written its message to stdout, the probe would have mistaken it for real output.

## 2. `tasklist` has no elapsed-time column

On POSIX the collector guards against pid reuse by comparing a process's *elapsed* time
(`ps -o etime=`) against the session's recorded start. Windows `tasklist` has no
equivalent, so that guard is simply unavailable there. The collector treats a pid that's
present in the table as `live` without the reuse check — failing toward *showing* a
session, never toward hiding one.

This is why an earlier version had a nasty bug: it fell back to the registry's
`updatedAt` heartbeat and declared a session `dead` once that went stale. But `updatedAt`
is stamped on status *transitions*, not on a timer, and a session parked at a permission
prompt stops transitioning — so a prompt left overnight vanished after six hours, and
Diagnostics claimed the process was "gone" while it was running. A present pid is now
trusted, full stop.

## 3. git and the registry disagree on path style

`git rev-parse --show-toplevel` returns POSIX-style paths **even on Windows**
(`E:/dev/acme-web`), while the session registry records native ones
(`E:\dev\acme-web\services\api`). A naive `cwd.startswith(root)` therefore never matches
on Windows, and the "path within the repo" comes out blank for every subfolder session.
Paths are normalised (`\`→`/`, drive-letter case, trailing separators) before comparison.

## 4. The macOS Local Network permission deadlock

This is the one that cost the most.

Since macOS Sequoia, an app must hold a **Local Network** grant to talk to devices on the
LAN. Terminal already has one, so everything works when you run the collector by hand —
which makes the app's failure look like your code, not a permission.

The trap: **macOS only shows the grant prompt when the connecting process is
long-lived.** The app's `ssh` child is refused and dies in milliseconds — far too short
for macOS to bother prompting. So: no prompt → no permission → every connection fails,
forever. A perfect deadlock, and the failure surfaces as `ssh: connect to host … port 22:
No route to host`, which looks like a network problem and isn't.

Things that are **not** the cause (all tested and ruled out): `LSUIElement`,
`ProcessType`, the bundle identifier, a stale TCC entry, and — importantly — running as a
LaunchAgent. Only **root daemons** are exempt from Local Network privacy; a user
LaunchAgent is subject to it just like the app, and being short-lived it can't trigger the
prompt either.

**The fix:** `LocalNetworkPermission.swift` opens an `NWConnection` to the host *from the
app process itself* and holds it open for several seconds at launch — long enough for
macOS to offer the dialog. Granted once, every subsequent `ssh` works.
`NSLocalNetworkUsageDescription` must be in the Info.plist or macOS won't even offer the
prompt. One subtlety: `NWConnection`'s resolver can't see SSH-config-only aliases, so the
probe qualifies the host as `<host>.local` (mDNS); `ssh` itself still uses the alias.

## 5. The SSH control socket makes every test lie

The single most disorienting one. The app shares an SSH connection across polls via
`ControlMaster` with `ControlPersist=300` — so a master connection stays open for **five
minutes** after any use. Any test you run within that window silently succeeds by reusing
the existing socket, whether or not a *fresh* connection would work.

During the Local Network debugging this produced results that flipped between runs for no
reason connected to the change under test — because sometimes a shell `ssh` from minutes
earlier had left a warm socket the app then borrowed. It read exactly like intermittent
networking and sent the whole investigation chasing ghosts.

**Rule:** before testing a *cold* connection, always tear down the master and clear the
control path first:

```bash
ssh -O exit <host> 2>/dev/null; rm -f ~/.crowsnest/cm/*
```

## 6. iCloud re-attaches extended attributes mid-build

If the project lives under `~/Desktop` or `~/Documents` (iCloud-synced), the file
provider re-attaches `com.apple.FinderInfo` to files between `xattr -cr` and `codesign` —
and `codesign` then rejects the bundle as having "resource fork, Finder information, or
similar detritus". Clearing the attributes isn't enough because they come straight back.
`build.sh` sidesteps it entirely by assembling and signing in a `mktemp -d` scratch
directory outside the synced tree, then copying the finished, signed bundle into place
with `ditto` (which preserves the signature; `cp -R` doesn't).
