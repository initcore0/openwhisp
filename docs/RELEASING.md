# Releasing OpenWhisp

OpenWhisp uses a **manual release cycle**. Merging a PR to `main` no longer ships
anything — a release is published **only when you push a version tag**. This lets
`main` move fast while users update only on deliberate releases, each with a real
changelog.

## Cut a release

From a clean, up-to-date `main`:

```bash
scripts/release.sh                 # patch bump   (1.0.0 -> 1.0.1)
scripts/release.sh minor           # minor bump   (1.0.0 -> 1.1.0)
scripts/release.sh major           # major bump   (1.0.0 -> 2.0.0)
scripts/release.sh --version 1.4.0 # set it explicitly
scripts/release.sh patch --dry-run # preview: shows the version, build, and the
                                   # commit list since the last tag; changes nothing
```

The script:

1. Verifies you're on `main`, the tree is clean, and local `main` matches
   `origin/main` (it fetches first).
2. Bumps `CFBundleShortVersionString` in `OpenWhisp/Info.plist` and commits it.
3. Computes the next **build number** (see below) and creates an annotated tag
   `v<version>+<build>` (e.g. `v1.0.1+156`).
4. After you confirm, pushes `main` and the tag. **The tag push triggers
   [`.github/workflows/release.yml`](../.github/workflows/release.yml)**, which
   builds, signs + notarizes, generates the appcast, and publishes the GitHub
   Release.

The script prints the Actions and Release URLs to watch.

## The two numbers in a tag: `v<version>+<build>`

- **`<version>`** — the human short version (`CFBundleShortVersionString`), what
  you bump with `major`/`minor`/`patch`.
- **`<build>`** — the monotonic `CFBundleVersion` that **Sparkle orders updates
  by**. The script sets it to `(highest build across all existing tags) + 1`, so
  it always climbs. This is load-bearing: Sparkle only offers an update whose
  build number is *higher* than the installed one, so a build that ever went
  *backwards* would leave the installed fleet stuck. Never hand-edit it lower.

CI reads both numbers back out of the tag and stamps them into `Info.plist` at
build time, so a re-run of the workflow for the same tag reproduces the same
version + build.

## The changelog

The GitHub Release notes are **auto-generated from the merged PRs / commits since
the previous tag** (GitHub's `generate-notes` — the categorized "What's Changed"
list plus a full-changelog compare link), followed by the install / Gatekeeper /
auto-update footer. There is nothing to write by hand; keep PR titles meaningful
and they become the changelog. You can still edit the release notes afterward in
the GitHub UI.

> The curated [`docs/changelog/changelog.json`](changelog.json) is a separate,
> hand-written narrative used for the marketing site and the Sparkle item title —
> it is not the source of the GitHub Release notes.

## Manual fallback

The workflow also has a **Run workflow** button (`workflow_dispatch`) on the
Actions tab. Without a tag ref it falls back to `Info.plist` + the run number for
the build — use it only to re-run a build, not as the normal release path.

## Signing

See [SIGNING_AND_NOTARIZATION.md](SIGNING_AND_NOTARIZATION.md) for the Developer
ID / notarization secrets. Without them the release still publishes an ad-hoc DMG
(forks keep working); with them it's signed, notarized, and auto-update-enabled.
