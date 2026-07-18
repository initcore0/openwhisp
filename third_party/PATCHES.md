# third_party fork patches

This file documents every OpenWhisp dependency that points at a **personal
fork** rather than an upstream release, so the fork's delta stays
reconstructible if the fork repo ever disappears. `scripts/check-third-party-pins.sh`
enforces that any `github.com/initcore0/*` URL under `third_party/` has an entry
here.

If you need to recreate a fork from scratch: check out the documented upstream
base tag, apply the diff below, and repin.

---

## initcore0/argmax-oss-swift (WhisperKit)

- **Consumed by:** `third_party/whisperkit-dep/Package.swift`
- **Upstream:** `argmaxinc/WhisperKit` (repo since renamed to `argmax-oss-swift`)
- **Upstream base:** tag `v1.0.0` — commit `25c62997041c134b03ca82731ce2f6fd2cae1eb9`
- **Fork pin:** commit `7e5f648249fde3eeabab02250529f63f16476e91`
  (branch `openwhisp/v1.0.0-input-device`)
- **Delta:** exactly ONE commit on top of `v1.0.0`
  (`feat(audio): add inputDeviceID passthrough to AudioStreamTranscriber`),
  touching a single file.

### Why the fork exists

`AudioStreamTranscriber` in v1.0.0 always captures from the system default input
device — there is no way to stream/live-transcribe from a *selected* device
(e.g. a virtual device such as BlackHole, or a specific USB mic). This is a
single-file backport of upstream **PR #503** (inputDeviceID passthrough).

We fork rather than pin the upstream contributor's branch because that branch
also carries ~60 files of divergent macOS-26 CoreML/ANE churn; our branch is
`v1.0.0` **plus only** this patch. Bump to an upstream release and drop the fork
once #503 lands upstream.

### The patch (v1.0.0 → fork pin)

`Sources/WhisperKit/Core/Audio/AudioStreamTranscriber.swift` — adds an optional
`inputDeviceID: DeviceID?` (default `nil` = system default input) that is stored
on the actor and passed through to `audioProcessor.startRecordingLive(...)`:

```diff
--- a/Sources/WhisperKit/Core/Audio/AudioStreamTranscriber.swift
+++ b/Sources/WhisperKit/Core/Audio/AudioStreamTranscriber.swift
@@ -39,6 +39,10 @@ public actor AudioStreamTranscriber {
     private let transcribeTask: TranscribeTask
     private let audioProcessor: any AudioProcessing
     private let decodingOptions: DecodingOptions
+    /// Optional input device to capture from. nil = system default input.
+    /// Lets callers stream from a specific device (e.g. a virtual device) instead
+    /// of always using the system default. Passed through to startRecordingLive.
+    private let inputDeviceID: DeviceID?
 
     public init(
         audioEncoder: any AudioEncoding,
@@ -52,6 +56,7 @@ public actor AudioStreamTranscriber {
         silenceThreshold: Float = 0.3,
         compressionCheckWindow: Int = 60,
         useVAD: Bool = true,
+        inputDeviceID: DeviceID? = nil,
         stateChangeCallback: AudioStreamTranscriberCallback?
     ) {
         self.transcribeTask = TranscribeTask(
@@ -70,6 +75,7 @@ public actor AudioStreamTranscriber {
         self.silenceThreshold = silenceThreshold
         self.compressionCheckWindow = compressionCheckWindow
         self.useVAD = useVAD
+        self.inputDeviceID = inputDeviceID
         self.stateChangeCallback = stateChangeCallback
     }
 
@@ -80,7 +86,7 @@ public actor AudioStreamTranscriber {
             return
         }
         state.isRecording = true
-        try audioProcessor.startRecordingLive { [weak self] _ in
+        try audioProcessor.startRecordingLive(inputDeviceID: inputDeviceID) { [weak self] _ in
             Task { [weak self] in
                 await self?.onAudioBufferCallback()
             }
```

### Reconstruction recipe

```sh
git clone https://github.com/argmaxinc/WhisperKit.git argmax-oss-swift
cd argmax-oss-swift
git checkout -b openwhisp/v1.0.0-input-device v1.0.0
# apply the diff above, then:
git commit -am "feat(audio): add inputDeviceID passthrough to AudioStreamTranscriber"
```

Repin `third_party/whisperkit-dep/Package.swift` to the resulting commit.
