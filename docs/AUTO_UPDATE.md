# Auto-update (Sparkle) — key management & the appcast pipeline

OpenWhisp ships with [Sparkle 2](https://sparkle-project.org) so installed copies
keep themselves current. This is the **one network call the app makes by
default**: a daily HTTPS fetch of a small, signed release feed (`appcast.xml`).
It sends only the app version and macOS version — no analytics, no system profile
(`SUEnableSystemProfiling` is deliberately left unset), no dictation data. Users
can turn it off in **Settings → General → Software Update**.

Every update is **EdDSA-signed**: the app verifies the download's signature
against the public key baked into `Info.plist` (`SUPublicEDKey`) and refuses
anything that doesn't match. Official builds are additionally Developer ID signed
and notarized (see [SIGNING_AND_NOTARIZATION.md](SIGNING_AND_NOTARIZATION.md)).

## How it fits together

| Piece | Where | Notes |
|-------|-------|-------|
| Framework fetch | `scripts/fetch-sparkle.sh` | Downloads the pinned Sparkle release tarball, verifies SHA-256, extracts `Sparkle.framework` + the `bin/` tools into `build/sparkle/` (never vendored in git). |
| Link flags | `scripts/sparkle-link-args.sh` | Sourced by `build.sh` **and** `build-dmg.sh`; adds `-D SPARKLE -F … -framework Sparkle` + the `@executable_path/../Frameworks` rpath. `SPARKLE=0` opts out (lean build; all Swift is `#if SPARKLE`-gated). |
| Bundle + sign | `scripts/bundle-sparkle-framework.sh` | Copies the framework into `Contents/Frameworks` and, for Developer ID builds, re-signs the nested XPC services / `Autoupdate` / `Updater.app` innermost-first with the hardened runtime. |
| App wiring | `OpenWhisp/Services/UpdaterManager.swift` | Wraps `SPUStandardUpdaterController`. Works from a menu-bar (`LSUIElement`) app with no main window. |
| Toggle logic | `OpenWhisp/Services/UpdatePreferences.swift` (in `OpenWhispCore`, unit-tested) | Resolves the auto-check preference: default ON, honors an explicit off. |
| Info.plist keys | `OpenWhisp/Info.plist` | `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`. |
| Appcast generator | `scripts/gen-appcast.sh` (+ `scripts/test-gen-appcast.sh`) | Emits a single-item `appcast.xml` with the signed enclosure. |
| Release pipeline | `.github/workflows/release.yml` | Signs the DMG, generates the appcast, publishes both as release assets. |

## Appcast hosting model

The appcast is published as a **GitHub Release asset**. `Info.plist`'s
`SUFeedURL` points at the stable redirect
`https://github.com/initcore0/openwhisp/releases/latest/download/appcast.xml`,
which always resolves to the newest release's `appcast.xml`. This is atomic with
the release and needs no separate hosting.

Crucially, the `<enclosure url>` inside the appcast is the **tag-specific** DMG
URL (`…/releases/download/<tag>/OpenWhisp.dmg`), **not** the `latest/download`
redirect — so the URL keeps resolving to that exact build even after newer
releases ship, and the EdDSA signature stays valid.

## Key management

The EdDSA keypair was generated once with Sparkle's `generate_keys`:

- **Public key** → committed in `OpenWhisp/Info.plist` as `SUPublicEDKey`.
- **Private key (seed)** → stored as the GitHub Actions secret
  `SPARKLE_ED_PRIVATE_KEY` (used by `sign_update` in the release workflow, read
  from stdin so it never lands in a process list), and backed up locally at
  `~/.openwhisp-sparkle-ed25519-private.key` (chmod 600). It is **never** committed.

To rotate or re-provision on a new machine (the pinned tools live under
`build/sparkle/<version>/extracted/bin` after any build, or run
`./scripts/fetch-sparkle.sh`):

```bash
# Generate a fresh keypair (prints the SUPublicEDKey to put in Info.plist):
BIN=build/sparkle/2.9.4/extracted/bin
"$BIN/generate_keys" --account openwhisp

# Export the private seed to set the GH secret + keep a local backup:
"$BIN/generate_keys" --account openwhisp -x /tmp/seed.txt
gh secret set SPARKLE_ED_PRIVATE_KEY < /tmp/seed.txt
install -m 600 /tmp/seed.txt ~/.openwhisp-sparkle-ed25519-private.key
rm /tmp/seed.txt
```

### If the private key is lost

Auto-updates for **already-installed copies** break: a new release signed with a
**different** key won't verify against the old `SUPublicEDKey` those installs
carry, so Sparkle rejects it (it will not silently install an unsigned update —
this is the security property working as intended). Recovery:

1. Generate a new keypair and update `SUPublicEDKey` in `Info.plist` + the
   `SPARKLE_ED_PRIVATE_KEY` secret.
2. Ship the new release as usual. Existing users **won't** auto-update to it.
3. Tell users to **download the latest DMG once** from the Releases page and
   reinstall. From that build forward, auto-update resumes with the new key.

So: keep the backup at `~/.openwhisp-sparkle-ed25519-private.key` safe, and
consider storing the seed in a password manager as well.

## Forks & the no-secret path

Everything degrades gracefully when the Sparkle secret (or the Developer ID
secrets) are absent:

- **No `SPARKLE_ED_PRIVATE_KEY` secret** → the release workflow skips appcast
  generation with a log line and publishes the DMG alone. The app still builds
  and runs; those users just don't get auto-update.
- **`SPARKLE=0` build** → the framework isn't fetched or bundled and the Software
  Update section is hidden (the `UpdaterManager` is a no-op stand-in).
- **Ad-hoc / self-signed DMG** → unchanged; the framework is resealed by the
  app's own signature. Notarization only re-signs Sparkle's nested components when
  a real Developer ID identity is present.

## Testing

`scripts/test-gen-appcast.sh` (wired into CI as the `appcast` job) generates a
throwaway key, signs a dummy DMG, runs `gen-appcast.sh`, and asserts the output
is well-formed XML with the right enclosure metadata and a signature that
verifies. `UpdatePreferencesTests` covers the toggle resolver under `swift test`.
