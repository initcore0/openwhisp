# third_party fork patches

This file documents every OpenWhisp dependency that points at a **personal
fork** rather than an upstream release, so the fork's delta stays
reconstructible if the fork repo ever disappears. `scripts/check-third-party-pins.sh`
enforces that any `github.com/initcore0/*` URL under `third_party/` has an entry
here.

If you need to recreate a fork from scratch: check out the documented upstream
base tag, apply the documented diff, and repin.

**Current state: no forks.** Every native dependency is pinned to an upstream
release.

---

## Retired forks

### initcore0/argmax-oss-swift (WhisperKit) — retired 2026-11

- **Was:** upstream `v1.0.0` + one commit backporting upstream **PR #503**
  (`inputDeviceID` passthrough on `AudioStreamTranscriber`, so streaming capture
  can target a selected input device instead of the system default).
- **Retired because:** #503 merged upstream (2026-08-13) and shipped in
  `argmaxinc/argmax-oss-swift` **v1.1.1** with the same
  `AudioStreamTranscriber(…, inputDeviceID:, …)` signature.
  `third_party/whisperkit-dep/Package.swift` now pins upstream `exact: "1.1.1"`.
- The fork repo can be archived; nothing in the build references it.
