# OpenWhisp Homebrew cask

`brew install --cask openwhisp` via a **self-hosted tap**,
`initcore0/homebrew-openwhisp`. The cask installs the same signed + notarized
DMG that the GitHub release ships; Sparkle (not Homebrew) handles updates
thereafter (`auto_updates true`).

Everything in **this** repo is ready. The remaining steps are the one-time
publish of the external tap repo, which only the maintainer can do.

## Users: how to install

Once the tap is published:

```sh
brew tap initcore0/openwhisp
brew install --cask openwhisp
```

(Or in one line: `brew install --cask initcore0/openwhisp/openwhisp`.)

Homebrew will not try to upgrade it — OpenWhisp keeps itself current in-app via
Sparkle. `brew uninstall --cask openwhisp` removes the app; add `--zap` to also
delete its support/cache/preference files.

## Maintainer: one-time tap publish

The tap is a plain GitHub repo named `homebrew-openwhisp` (the `homebrew-`
prefix is what lets `brew tap initcore0/openwhisp` find it). It just needs a
`Casks/` directory with the cask file.

1. **Create the repo** `github.com/initcore0/homebrew-openwhisp` (public, empty).

2. **Copy the cask into it** from this repo:

   ```sh
   git clone https://github.com/initcore0/homebrew-openwhisp.git
   cd homebrew-openwhisp
   mkdir -p Casks
   cp /path/to/openwhisp/packaging/homebrew/Casks/openwhisp.rb Casks/openwhisp.rb
   git add Casks/openwhisp.rb
   git commit -m "openwhisp: initial cask"
   git push
   ```

   After the push, `brew tap initcore0/openwhisp && brew install --cask openwhisp`
   works immediately (it points at the already-published v1.0.0+155 release DMG).

3. **Enable automatic cask bumps on each release.** Create a GitHub token that
   can push to the tap repo and add it as a secret on **this** repo
   (`initcore0/openwhisp`):

   - Fine-grained PAT scoped to `initcore0/homebrew-openwhisp` with
     **Contents: Read and write** (or a classic PAT with `repo`). A machine
     account is cleanest but not required.
   - Add it under **Settings → Secrets and variables → Actions** as
     **`TAP_PUSH_TOKEN`**.

   With that secret present, the release workflow's *"Bump Homebrew cask + push
   to tap"* step recomputes the DMG sha256 on every tagged release and pushes the
   updated `Casks/openwhisp.rb` to the tap. **Until the secret is set, that step
   no-ops with a clear log** — releases keep working, the cask just isn't
   auto-bumped.

## How the pieces fit

- `Casks/openwhisp.rb` — the cask. `version "1.0.0,155"` is Homebrew's
  `version,revision`; the `url` rebuilds the release tag `v1.0.0+155` from both
  halves. `zap` trashes the app's real `~/Library` paths (Application
  Support/OpenWhisp, Caches + Preferences under `com.openwhisp.app`).
- `../../scripts/bump-cask.sh` — rewrites the version + sha256 lines from a built
  DMG and pushes to the tap. Guarded on `TAP_PUSH_TOKEN`.
- `../../.github/workflows/release.yml` — runs `bump-cask.sh` after a signed +
  notarized release publishes.

## Updating the cask manually

If you ever need to bump it by hand (e.g. before the automated step is wired up):

```sh
# from the openwhisp repo, with the release DMG downloaded to dist/OpenWhisp.dmg
scripts/bump-cask.sh --version 1.0.0 --build 155 --dmg dist/OpenWhisp.dmg
```

Without `TAP_PUSH_TOKEN` in the environment it only rewrites the local cask
file; copy that into the tap repo and push.
