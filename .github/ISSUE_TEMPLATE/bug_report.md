---
name: Bug report
about: Something isn't working. Please read SUPPORT.md first.
labels: bug
---

<!--
Before filing: check docs/troubleshooting.md. Most "empty list" cases are the macOS
Local Network prompt or an untrusted SSH host, both covered there.
-->

## What happened

<!-- What you expected vs what you saw. -->

## Diagnostics (required)

The app writes the real reason to disk, since it never shows errors in the list.
Paste the output of:

```
cat ~/.crowsnest/last-poll.log
```

<!-- paste here -->

## Environment (required)

- macOS version (`sw_vers`):
- Remote machine OS, if any (Windows / Linux / macOS / none):
- Claude Code version (`claude --version`):

<!--
This is a personal tool published as-is (see SUPPORT.md). Issues are welcome but may
go unanswered, and support for setups I can't test is unlikely. A PR is more likely to
land than a request.
-->
