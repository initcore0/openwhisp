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

## Notes

- **Without a Developer ID cert**, `build-dmg.sh` falls back to the self-signed or
  ad-hoc identity and skips hardening/timestamping (they aren't notarizable). Behavior
  for local dev is unchanged; `NOTARIZE=1` errors out early if no Developer ID is present.
- **First notarization** of a new bundle id can take a few minutes; subsequent ones
  are usually under a minute.
- The entitlements file is a **build input** (passed via `codesign --entitlements`),
  not a bundle resource — it is never copied into `Contents/`.
- CI (`release.yml`) still produces the ad-hoc DMG; moving notarization into CI needs
  the cert (.p12) + notary credentials as GitHub Actions secrets — a separate step.
