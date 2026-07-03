# Signing & notarizing a distributable build

By default OpenWhisp builds are **ad-hoc signed** (or self-signed for stable local
TCC). To ship a DMG that opens on other Macs **without a Gatekeeper warning**, you
need an Apple **Developer ID Application** certificate and **notarization**. This
is the one-time setup plus the per-release command.

## One-time setup (per machine / Apple account)

1. **Enroll in the Apple Developer Program** ($99/yr): <https://developer.apple.com/programs/>.

2. **Create a "Developer ID Application" certificate.** Easiest via Xcode:
   *Settings → Accounts → (your Apple ID) → Manage Certificates → + → Developer ID
   Application.* This creates the cert **and** its private key in your login keychain.
   Verify:
   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   # → Developer ID Application: Your Name (TEAMID)
   ```

3. **Create an app-specific password** for notarization at
   <https://account.apple.com> → *Sign-In & Security → App-Specific Passwords*.
   Note your **Team ID** (the 10-char code in the cert name).

4. **Store the notarization credentials** in the keychain once (the build reads this
   profile by name; nothing secret goes in the script):
   ```bash
   xcrun notarytool store-credentials "openwhisp-notary" \
     --apple-id "you@example.com" \
     --team-id "YOURTEAMID" \
     --password "app-specific-password"
   ```

## Per-release build

With the Developer ID cert installed, `build-dmg.sh` **auto-detects** it and signs
with the **hardened runtime + secure timestamp** (both required for notarization).
Nested code (the whisper.cpp / llama.cpp dylibs + helper executables) is signed
**inside-out** — `--deep` is unreliable under the hardened runtime.

```bash
# Sign (hardened runtime) + notarize + staple, in one go:
NOTARIZE=1 ./build-dmg.sh release
```

That will:
1. sign every nested dylib/executable, then the app bundle (with entitlements);
2. build + sign the DMG;
3. `xcrun notarytool submit --wait` (blocks until Apple returns a verdict — fails
   loudly if rejected, with a log URL);
4. `xcrun stapler staple` the ticket so it passes Gatekeeper **offline**;
5. `spctl --assess` as a final check.

Override the identity or profile if needed:
```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="openwhisp-notary" \
NOTARIZE=1 ./build-dmg.sh release
```

## Signing in CI (GitHub Actions)

`release.yml` signs + notarizes automatically **when the signing secrets are set**;
without them it falls back to the ad-hoc DMG (so forks still build). To enable it, add
these **repository secrets** (Settings → Secrets and variables → Actions):

| Secret | What it is |
| --- | --- |
| `MACOS_CERT_P12_BASE64` | Your Developer ID Application cert **exported as a `.p12`** (cert + private key), base64-encoded. |
| `MACOS_CERT_PASSWORD` | The password you set when exporting the `.p12`. |
| `KEYCHAIN_PASSWORD` | Any throwaway string — password for the temporary CI keychain. |
| `NOTARY_APPLE_ID` | Your Apple ID email. |
| `NOTARY_TEAM_ID` | Your 10-char Team ID. |
| `NOTARY_PASSWORD` | An app-specific password (from account.apple.com). |

**Export the `.p12`** from Keychain Access: find *Developer ID Application: …*, expand
it to include its private key, select both, right-click → **Export 2 items…** → `.p12`
→ set a password (that's `MACOS_CERT_PASSWORD`). Then:

```bash
base64 -i DeveloperID.p12 | pbcopy   # paste as MACOS_CERT_P12_BASE64
```

The workflow imports the cert into a temp keychain (`scripts/ci-import-cert.sh`),
derives `SIGN_IDENTITY` from it, and runs `NOTARIZE=1 ./build-dmg.sh release` with
the notary credentials passed directly (no keychain profile needed on the runner).

If `MACOS_CERT_P12_BASE64` is set but any of the other five secrets are missing, the
workflow **fails fast** at the "Detect signing availability" step with the list of
missing names, instead of erroring twenty minutes later inside notarytool.

### Protecting the signing secrets (recommended)

Repository-level secrets are visible to **every workflow run**, including
`workflow_dispatch` runs of `release.yml` launched from an arbitrary branch — so
anyone with write access could dispatch the workflow from a branch with a modified
build script and reach the cert. To close that off, move the six secrets into a
**GitHub Environment** (Settings → Environments → e.g. `release`):

1. Create the environment, add the same six secrets there, and delete the
   repository-level copies.
2. Under *Deployment branches*, restrict it to `main` only.
3. Add `environment: release` to the `release` job in `release.yml`.

With that, the secrets are only injected when the workflow runs against `main`, and
optionally only after a required-reviewer approval. For a solo-maintainer repo this
is defense-in-depth rather than a must, but it's cheap and it's the standard
mitigation for "CI holds my code-signing identity."

## Notes

- **Without a Developer ID cert**, `build-dmg.sh` falls back to the self-signed or
  ad-hoc identity and skips hardening/timestamping (they aren't notarizable). Behavior
  for local dev is unchanged; `NOTARIZE=1` errors out early if no Developer ID is present.
- A **local** build with the Developer ID cert installed auto-signs with the hardened
  runtime even without `NOTARIZE=1` — that's fine (it still runs locally); only
  `NOTARIZE=1` does the Apple round-trip + staple.
- **First notarization** of a new bundle id can take a few minutes; subsequent ones
  are usually under a minute.
- The entitlements file is a **build input** (passed via `codesign --entitlements`),
  not a bundle resource — it is never copied into `Contents/`.
