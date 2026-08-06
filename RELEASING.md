# Releasing

How versions, tags, and releases work for this project, and the honest state of
distribution.

## Versioning

[Semantic versioning](https://semver.org): `MAJOR.MINOR.PATCH`.

- **PATCH** — a bug fix, no behaviour change for existing users.
- **MINOR** — a new feature, backward compatible.
- **MAJOR** — a breaking change (e.g. the collector's JSON contract changes, or the
  minimum macOS version rises).

Two numbers live in `build.sh`'s Info.plist and must both bump on a release:
- `CFBundleShortVersionString` — the human version, e.g. `1.1.0`.
- `CFBundleVersion` — a monotonic build number, e.g. `2`, `3`, … (just increment it).

## Cutting a release

This repo has two remotes with different histories: **Forgejo** (`main`, full commit
history, private) and **GitHub** (`main`, one squashed clean commit, the public face).
Releases are cut on the GitHub side.

1. Land your changes on `main` and update `CHANGELOG.md` (move items under a new
   `## [x.y.z] — YYYY-MM-DD` heading) and the two version numbers in `build.sh`.
2. Push the full history to Forgejo: `git push forgejo main`.
3. Rebuild the clean public commit and push it to GitHub:
   ```bash
   git checkout github-clean && git checkout main -- . && git add -A
   git commit --amend --no-edit
   git push -f github github-clean:main
   git checkout main
   ```
4. Tag and release on GitHub:
   ```bash
   git tag -a vX.Y.Z github-clean -m "Crow's Nest X.Y.Z"
   git push github vX.Y.Z
   gh release create vX.Y.Z --repo <owner>/crowsnest --title "Crow's Nest X.Y.Z" \
       --notes-file <(sed -n '/## \[X.Y.Z\]/,/## \[/p' CHANGELOG.md)
   ```

## Distribution — the honest state

Today the only supported install is **build-from-source** (`git clone && ./build.sh`).
This is deliberate, and it's the right call for now:

- **No Gatekeeper problem.** An app you compile and sign locally isn't quarantined, so
  it just runs. A *downloaded* app is a different story (below).
- **No cost, no account.** `build.sh` ad-hoc signs (`codesign --sign -`); the user needs
  only the Xcode command line tools.

### Why there's no downloadable `.app` or Homebrew cask (yet)

Shipping a **pre-built** binary that opens without a Gatekeeper wall requires an **Apple
Developer Program** membership ($99/year) to get a *Developer ID* certificate and to
**notarize** the app. Without that, a downloaded `.app` is blocked with "cannot be opened
because the developer cannot be verified", and users have to right-click → Open or strip
the quarantine attribute by hand — a bad first experience.

A **Homebrew cask** just points at a downloadable artifact, so it inherits the same
notarization requirement to be pleasant.

**Recommendation:** stay build-from-source until there's real demand. If the project gains
traction, the upgrade path is, in order:
1. Join the Apple Developer Program, sign with Developer ID, and notarize in `build.sh`.
2. Attach a notarized `CrowsNest.app.zip` to each GitHub Release (via `gh release upload`).
3. Publish a Homebrew tap (`brew tap <owner>/crowsnest`) with a cask pointing at that
   release asset.

None of that is worth doing for a handful of users, and all of it is a standing
maintenance cost — which is exactly what the project's "personal tool, as-is" posture is
trying to avoid.
