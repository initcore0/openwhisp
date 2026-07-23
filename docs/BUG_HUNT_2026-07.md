# Bug Hunt — July 2026

A full-app sweep (MAK-style bug hunt) run 2026-07-22 on `main` @ e3a0f7d: 14
scoped finder passes over every subsystem (AppState, audio capture, engines,
LLM/refine, agent bridge + LAN sync, text output, persistence, coordinators,
UI, CLI/MCP, build scripts, plus cross-cutting pattern sweeps), followed by
adversarial verification of every finding (high-severity findings needed two
independent verifiers to survive). 85 raw findings -> 74 after dedup ->
**68 confirmed**, 6 refuted.

**31 confirmed findings are fixed in this PR** (see the commit series). The
remaining **37 are catalogued below as follow-ups** — real, verified, but
needing either a design decision, a live-mic/manual pass, or a redesign too
large to bolt onto this PR.

## Fixed in this PR

- **[high/bug]** `OpenWhisp/Models/AppState.swift:2150` — Streaming onError fence captures wiring-time session ID — every engine error is silently dropped.
  *Fix:* onError moved into the per-session callback rebind (bindStreamingSessionCallbacks).
- **[high/race]** `OpenWhisp/Models/AppState.swift:4555` — Stale applyRefineLLM completion aborts a NEWER session's in-flight refine, silently losing that dictation.
  *Fix:* Stale completion now aborts only if the flow still holds ITS refine (state match on step1+instruction).
- **[high/bug]** `OpenWhisp/Services/SpeechAnalyzerStreamingEngine.swift:260` — SpeechAnalyzerStreamingEngine final drops the volatile tail: only finalized segments are delivered and the analyzer is never finalized.
  *Fix:* Volatile tail tracked and appended to the delivered final (analyzer-finalize rework deferred pending live-mic pass).
- **[medium/bug]** `OpenWhisp/Models/AppState+Sync.swift:33` — sync.push reports accepted:true with nonzero mergedCounts.history while AppState silently drops the write when history is disabled.
  *Fix:* SyncStore.syncHistoryEnabled added; push drops incoming history and reports 0 when disabled. +test
- **[medium/perf]** `OpenWhisp/Models/AppState.swift:2259` — @Published audioLevel updated at audio-buffer rate on the app-wide AppState invalidates every observing window.
  *Fix:* Sub-1% level changes no longer published (epsilon gate in updateAudioLevel).
- **[medium/perf]** `OpenWhisp/Models/AppState.swift:3239` — Switching to WhisperKit with an unstaged model starts two concurrent downloads of the same model (warm guard checks the GGML flag).
  *Fix:* Warm path gates on whisperKitDownloadingModel/isStaged and routes unstaged models to the managed single-flight download.
- **[medium/race]** `OpenWhisp/Models/AppState.swift:6699` — bridgeStartDictation busy guard doesn't cover the TTS question-reading window — a second agent dictate overwrites onSessionEnd and strands the first caller forever.
  *Fix:* Busy guard extended: agentDictateReadingQuestion / armed onSessionEnd now reject a second dictate.
- **[medium/race]** `OpenWhisp/Models/FileTranscriptionCoordinator.swift:297` — Enhance completion racing removeJob tears down the next job and wedges the file queue.
  *Fix:* Enhance completion guarded on activeJobID == jobID (same as the decode loop).
- **[medium/bug]** `OpenWhisp/Models/FileTranscriptionCoordinator.swift:346` — Persisted queued jobs never resume after relaunch — nothing pumps the restored queue.
  *Fix:* pump() deferred-called after loadPersisted() in init.
- **[medium/race]** `OpenWhisp/Models/MeetingPipelineCoordinator.swift:640` — delete() during leg transcription cannot stop the leg engine — abandoned work overlaps the next meeting's transcription.
  *Fix:* Per-chunk activeTranscribeID guard threaded into transcribeLeg (LegSuperseded).
- **[medium/bug]** `OpenWhisp/Services/AudioRecorder.swift:331` — Live-chunk rotation timer (and meter timer) scheduled in .default run-loop mode — stalls while the status-bar menu is open.
  *Fix:* Timers created unscheduled and added to RunLoop.main in .common mode.
- **[medium/bug]** `OpenWhisp/Services/JSONStore.swift:48` — JSONStore.load silently returns default on read failure of an existing file — next save permanently overwrites the store.
  *Fix:* Read-failure branch distinguishes ENOENT from real errors; quarantines to .unreadable-<epoch>. +test
- **[medium/leak]** `OpenWhisp/Services/LANBridgeServer.swift:342` — LAN sync connections have no post-handshake idle timeout or TCP keepalive — ghost connections permanently exhaust the 8-connection cap.
  *Fix:* TCP keepalive enabled on the LAN listener (30s idle / 10s interval / 3 probes).
- **[medium/bug]** `OpenWhisp/Services/LLMBenchRunner.swift:43` — LLMBenchRunner's private LlamaServerEngine shares the production PID file and its init kills the app's live llama-server.
  *Fix:* LlamaServerEngine takes a per-instance ManagedServerSpec; bench runner uses its own PID/log files.
- **[medium/race]** `OpenWhisp/Services/LlamaServerEngine.swift:190` — Transient /health probe timeout kills a busy llama-server mid-generation (relaunch path ignores inFlight).
  *Fix:* Fast-path fall-through returns success instead of tearing down when the same-model child is alive with inFlight > 0.
- **[medium/leak]** `OpenWhisp/Services/MeetingCaptureSession.swift:374` — Mic-leg failure and stop-during-SCK-startup abandon a live ScreenCaptureKit capture (stopCapture never called).
  *Fix:* teardownLegs now stops the SCK capture itself (idempotent — normal stop already nils the stream).
- **[medium/perf]** `OpenWhisp/Services/SmartFormatter.swift:184` — SmartFormatter recompiles ~28 regexes per call and runs on every Apple Speech partial over the full cumulative transcript, on the main actor; vocabulary matching doubles it.
  *Fix:* All static SmartFormatter patterns precompiled once (28 compiles/call -> 0).
- **[medium/race]** `OpenWhisp/Services/WhisperKitStreamingEngine.swift:224` — runStop fires self.onFinal read at fire time — SessionCallbacks snapshot omits `final`, so a stale final can be delivered with the successor session's identity.
  *Fix:* onFinal snapshotted at stop-enqueue time in both WhisperKit and Parakeet streaming engines.
- **[medium/perf]** `OpenWhisp/Views/Settings/GeneralPane.swift:25` — GeneralPane body performs an SMAppService XPC status check on every render.
  *Fix:* SMAppService status snapshotted on appear/toggle-change instead of per render.
- **[medium/perf]** `build-dmg.sh:81` — Release DMGs ship an unoptimized (-Onone) app binary: the [debug|release] CONFIG argument is dead in both compile paths.
  *Fix:* CONFIG now wires -O for release in build.sh + build-dmg.sh; package.sh builds release.
- **[low/bug]** `OpenWhisp/Models/AppState.swift:5245` — Stale delayed overlay-hide task hides the agent's question overlay mid-TTS (reading window not in the hide predicate).
  *Fix:* overlayIsSettled predicate extracted; includes !agentDictateReadingQuestion; all three hide sites use it.
- **[low/perf]** `OpenWhisp/Models/AppState.swift:5740` — Up to three synchronous whole-file JSON writes on the main actor per completed dictation (history encoded twice when the retention sweep fires).
  *Fix:* History+stats writes moved to a background serial queue; retention sweep coalesced into one write.
- **[low/race]** `OpenWhisp/Services/AgentBridgeServer.swift:39` — allowUnsignedClients is written on the main thread and read on connection threads with no synchronization.
  *Fix:* allowUnsignedClients guarded by the server's stateLock.
- **[low/perf]** `OpenWhisp/Services/FileOutputTarget.swift:96` — FileOutputTarget append reads the entire file on every dictation just to choose a 2-character separator.
  *Fix:* Append separator derived from the file's last 2 bytes (O(1)); byte/String parity test added.
- **[low/race]** `OpenWhisp/Services/FileOutputTarget.swift:119` — Concurrent appends to the same file from per-call FileOutputTarget instances can interleave or overwrite entries (seekToEnd+write, no O_APPEND).
  *Fix:* FileOutputTarget's serial queue made static (process-wide across per-call instances).
- **[low/race]** `OpenWhisp/Services/LlamaServerEngine.swift:78` — idleTimeout is an unsynchronized var written from the main actor and read under serverLock on background queues.
  *Fix:* idleTimeout guarded by serverLock (locked paths read the backing field).
- **[low/race]** `OpenWhisp/Services/LlamaServerEngine.swift:336` — Fired-but-cancelled idle-timer handler has no identity check and can tear down a just-started warm-up server.
  *Fix:* Idle-timer handler bails unless it is still the current timer (identity check under the lock).
- **[low/perf]** `OpenWhisp/Services/Vocabulary.swift:244` — VocabularySubstitutor recompiles every rule's regex on each call, and runs the full rule scan twice per live chunk on the main actor.
  *Fix:* Compiled rule regexes cached process-wide, shared by apply() and firedSubstitutionIDs().
- **[low/race]** `OpenWhisp/Services/WatchFolderMonitor.swift:27` — WatchFolderMonitor.paths written on main while rescan reads it on the FSEvents queue.
  *Fix:* paths confined to the FSEvents queue (assigned via queue.async before the stream starts).
- **[low/bug]** `OpenWhisp/Services/WhisperKitEngine.swift:226` — WhisperKitEngine: a failed auto-language-detect Task is cached forever — one transient failure poisons every subsequent chunk of the session.
  *Fix:* Failed detect Task cleared from the cache before rethrow (mirrors clearFailedLoad).
- **[low/perf]** `OpenWhisp/Views/Settings/CleanupPane.swift:557` — Cleanup pane body re-reads and re-decodes llm-manifest.json from disk on every SwiftUI render.
  *Fix:* Manifest cached in a static let (bundle resource, immutable per run).

## Deferred follow-ups

Verified issues NOT fixed here, grouped by area. Each entry keeps the
verifier-confirmed failure scenario and the suggested fix so it can be filed
as its own ticket.

### AppState / session lifecycle

#### Session not pinned to its engine: mid-session engine switch stops the wrong engine and can leave the Apple Speech mic hot forever
`OpenWhisp/Models/AppState.swift:1386` — medium/race, fix risk moderate

The two contexts: (a) the live dictation session, whose stop paths resolve `activeStreamingEngine` from the CURRENT setting at stop time, and (b) the Settings UI mutating `transcriptionEngine` (didSet, line 304-326) mid-session — fully reachable during a hands-free locked session or an agent session, when the user is free to click around Settings while the mic is live. `transcriptionEngine.didSet` runs rebuildFileEngine() with no sessionActive/isRecording guard. rebuildFileEngine (2387-2409) stops and replaces whisperKitStreamEngine, parakeetStreamEngine and speechAnalyzerStreamEngine — but never appleSpeechEngine. Failure scenario A (hot mic): session live on appleSpeech; user switches engine to parakeet; the running AppleSpeechEngine is untouched; on stop, stopAppleSpeech (3525) calls `activeStreamingEngine.stop(cancel: false)` which now resolves to the never-started parakeet engine — …

*Suggested fix:* Pin the engine instance per session: capture `let engine = activeStreamingEngine` in startStreamingSession into a `currentSessionStreamingEngine` field, and have stopAppleSpeech/cancelDictation stop THAT instance (clearing it in finishSessionUI). Additionally, make rebuildFileEngine either refuse/defer while sessionActive, or stop appleSpeechEngine too so no engine survives a rebuild running.

#### Per-partial synchronous cross-process AX secure-field probe + full re-clean of the accumulated utterance on the main thread in liveChunks streaming
`OpenWhisp/Models/AppState.swift:3572` — medium/perf, fix risk moderate

In a liveChunks streaming session (isLiveChunkSession, set at line 3394), handleAppleSpeechPartial runs for every recognizer partial — several times per second during continuous speech — on the main actor. Each invocation does two pieces of unbounded/quadratic work: (1) line 3554 `postProcess(rawText)` constructs a fresh TranscriptCleaner and re-cleans the ENTIRE accumulated utterance (vocabulary substitution, smart formatting, spoken punctuation, number normalization) — O(utterance length) per partial, O(n²) over a long dictation; (2) line 3572 SecureFieldDetector.focusedFieldIsSecure() performs three synchronous cross-process AX round-trips (AXUIElementCopyAttributeValue for focused element, role, and subrole — SecureFieldDetector.swift:17-37) with no caching and no AXUIElementSetMessagingTimeout anywhere in the app (grep confirms zero call sites). The failure/cost scenario: dictating …

*Suggested fix:* Cache the secure-field verdict per (focused-element) with a short TTL (e.g. re-probe at most every 300-500 ms, or only when the frontmost app / focused element changes via an AX focus observer), and call AXUIElementSetMessagingTimeout with a sub-second timeout on the system-wide element so a hung target app can't stall the main thread. For postProcess, clean only the delta or debounce the full clean to the display refresh rather than every partial.

#### Live-chunk finalize unconditionally overwrites the clipboard with the transcript, permanently defeating the default-on 'Restore clipboard after pasting' setting (and the directAX no-clipboard promise)
`OpenWhisp/Models/AppState.swift:4720` — medium/bug, fix risk moderate

In the liveChunks finalize branch, `textOutput.setClipboard(text)` runs unconditionally. Because TextInserter's deferred restore deliberately vetoes itself when the pasteboard changed since its own write (`guard pb.changeCount == expectedChangeCount else { return }`, with setClipboard named as a legitimate later writer), this write both replaces the user's clipboard with the transcript AND cancels the pending +1.0 s restore of the user's original clipboard carried in pendingRestoreItems. Net effect: with restoreClipboard = true (the default, surfaced in Settings as 'Puts back whatever was on your clipboard once the text is pasted'), every live-chunk dictation still ends with the user's clipboard permanently replaced. The whole-paste (preview/finalOnly) branch has no such write and DOES restore, so the same setting behaves differently per output mode. It also runs when insertionMode == …

*Suggested fix:* Gate the finalize setClipboard on the user's intent: skip it when restoreClipboard is enabled (let the last chunk's deferred restore run), or when insertionMode is directAX; if 'result stays on clipboard' is a desired feature, make it an explicit setting applied consistently in both live-chunk and whole-paste modes.

#### stopAppleSpeech's 2 s fallback double-applies postProcess (non-idempotent vocabulary substitutions) to the final transcript
`OpenWhisp/Models/AppState.swift:3539` — low/bug, fix risk moderate

handleAppleSpeechPartial stores already-cleaned text into streamingText (line 3554-3555: `let text = postProcess(rawText); streamingText = text`). The stuck-session fallback in stopAppleSpeech then calls `handleAppleSpeechFinal(self.streamingText, ...)` (line 3539), and handleAppleSpeechFinal unconditionally runs `postProcess(editedRaw, isFinalTranscript: true)` on it again (line 3612). The same double-clean happens when the engine delivers an empty final and line 3595 falls back to streamingText. Concrete failure: any user substitution rule whose replacement contains its trigger as a whole phrase — e.g. "mini" → "Mac mini" — is applied twice on this path, producing "Mac Mac mini" in the pasted final. Trigger conditions: the streaming engine's genuine final never lands within 2 s of stop (the WhisperKit-streaming teardown case the comment at 3530-3534 names as this timer's purpose), or …

*Suggested fix:* Keep the raw (pre-postProcess) accumulated transcript alongside streamingText (e.g. a lastRawPartial field updated in handleAppleSpeechPartial) and pass THAT to handleAppleSpeechFinal from the fallback timer; or add a flag so handleAppleSpeechFinal skips the vocabulary-substitution stage when the input is known to be already cleaned (running only the isFinalTranscript-specific meta-instruction strip).

#### Full-transcript regex cleanup runs on every streaming partial on the main actor, recompiling patterns per call
`OpenWhisp/Models/AppState.swift:3554` — low/perf, fix risk moderate

handleAppleSpeechPartial calls `postProcess(rawText)` on every recognizer partial. Apple Speech/Parakeet partials carry the WHOLE transcript so far and arrive several times per second, so for an N-char dictation this is O(N) cleaning per partial (O(N²) over the session) on the main actor while it is also servicing 30 Hz audio-level hops, elapsed-timer ticks, and (in liveChunks mode) per-delta AX secure-field checks + inserts. postProcess (4981-4992) builds a fresh TranscriptCleaner per call, scans all vocabulary substitutions via firedSubstitutionIDs, and SmartFormatter applies its pattern tables through String.replacingOccurrences(options: .regularExpression) (e.g. the 16-entry punctuationReplacements loop at SmartFormatter.swift:176-189), which recompiles each ICU pattern on every invocation — dozens of regex compiles per partial. Cost is negligible for short utterances but grows …

*Suggested fix:* For partials, run a lightweight cleaning tier (vocabulary substitutions + spoken punctuation only, or skip cleaning and show the raw partial), reserving the full TranscriptCleaner pass for finals/chunk boundaries; and cache compiled NSRegularExpression instances in SmartFormatter as static lets instead of using the .regularExpression String option.

#### ScriptRunner.run blocks the main actor for up to ~3.7 s in the finalize path; the 'Running script...' status set just before can never render
`OpenWhisp/Models/AppState.swift:4626` — low/perf, fix risk moderate

completeFinalText (a @MainActor method) calls the synchronous ScriptRunner.run inline: `statusMessage = "Running script..."` followed immediately by the blocking call. The main thread never returns to the run loop between the two, so that status can never paint — the overlay freezes on the previous message, and all UI (level meter, elapsed timer, hotkey handling) stalls for the script's duration. The block is bounded but larger than the nominal 2 s: waitGroup.wait(2.0) + SIGTERM grace wait(0.25) + readGroup.wait(0.5) (plus an UNBOUNDED readGroup.wait() after the pipe close) + writeGroup waits (0.5 + 0.5) sums to ~3.75 s worst case per dictation with the opt-in script post-processor enabled. ScriptRunner's doc says it is 'intentionally synchronous' because 'the UI already shows Polishing…/Done' — but that premise is wrong on the main actor: the UI shows a stale frozen frame, not …

*Suggested fix:* Run ScriptRunner.run on a background queue (or wrap in an async continuation) and complete the finalize continuation on the main actor with the result — the session-race surface can be handled with the same sessionID staleness fence the other async steps already use; then 'Running script...' actually renders.

#### Crash-recovery marker (CaptureRecoveryMarker/CrashRecoveryResolver) is dead code — never written on capture start, never consulted at launch
`OpenWhisp/Services/CrashRecoveryState.swift:10` — low/debt, fix risk moderate

The type doc promises: "A marker the app writes when a dictation session starts capturing and clears when it stops cleanly (MAK-40 crash recovery). If the marker survives to the next launch, the previous session died mid-dictation ... and its partially-captured audio may still be on disk." Repo-wide search shows the ONLY references to `CaptureRecoveryMarker` and `CrashRecoveryResolver` are the type's own file and Tests/OpenWhispCoreTests/CrashRecoveryStateTests.swift — no code in OpenWhisp/ writes the marker at capture start, clears it on clean stop, or calls `CrashRecoveryResolver.decide` at launch. The feature the tests certify does not exist in the running app: a crash/force-quit/power loss mid-dictation still silently discards the session with no recovery offer. This is precisely the "tested core, dead wiring" failure mode the project has been bitten by before (tests pass, feature …

*Suggested fix:* Wire it: persist the marker (via JSONStore) in the capture-start path (where `recordingStartedAt` is set / the recorder opens its WAV), clear it in the clean-stop path, and run `CrashRecoveryResolver.decide` during AppState launch init, surfacing the offerRecovery prompt through the existing re-transcribe plumbing (`reTranscribeHistoryEntry` already shows the pattern). Or delete the type and its tests if the feature was descoped.

#### reapStaleServer blocks the main actor for 0.5s+ when a stale server exists
`OpenWhisp/Services/ManagedServerProcess.swift:276` — low/perf, fix risk moderate

reapStaleServer does `kill(pid, SIGTERM); Thread.sleep(forTimeInterval: 0.5); if isOwned(pid) { kill(pid, SIGKILL) }` synchronously on the calling thread. LlamaServerEngine.init calls it (LlamaServerEngine.swift L91), and that init runs on the main actor: AppState.ensureLlamaEngine (AppState.swift L581-584, @MainActor class) constructs the engine lazily on the FIRST refine after launch, and LLMBenchRunner (@MainActor) constructs one per bench run. So after any crash/force-quit that left a llama-server alive, the first refine of the next launch freezes the UI (and the dictation pipeline's main-actor work) for at least 500ms, plus two proc_pidpath lookups. Rare trigger (needs a live stale PID), bounded cost, but it lands exactly at the start of the hot refine path.

*Suggested fix:* Move the reap off the calling thread — e.g. dispatch reapStaleServer to a utility queue from the engine init (it has no ordering dependency on the first ensureRunning, which reserves a fresh port anyway), or replace the fixed sleep with the async SIGTERM→SIGKILL escalation already used by terminateAsync.

### Windows & UI

#### Settings and Tips windows stay fully alive and subscribed to AppState forever after close
`OpenWhisp/AppMain.swift:659` — medium/leak, fix risk moderate

openSettings() and openTips() create their windows with `isReleasedWhenClosed = false`, store them in `settingsWindow`/`tipsWindow`, and never clear them or detach the contentViewController on close (no delegate, no willClose handling in AppMain — contrast onboarding, which nils its window via the onClose callback, and the overlay, which detaches its hosting controller on hide). Retention for fast reopen is intentional (WindowCloseObserver.swift:12-14 documents 'Settings — a retained window that reopens'), but the side effect is that the entire SettingsView tree — NavigationSplitView, sidebar, and the currently selected pane, all `@ObservedObject var appState` — remains installed in the closed window and subscribed to AppState.objectWillChange for the rest of the process lifetime. Every @Published mutation (the ~30 Hz audioLevel and per-partial streamingText publishes during EVERY …

*Suggested fix:* On window close (an NSWindow.willCloseNotification observer or window delegate in AppMain), either nil out settingsWindow/tipsWindow (rebuild on next open — Tips is static and cheap; Settings builds in well under a frame) or detach `window.contentViewController = nil` and re-attach a fresh SettingsView on reopen, mirroring what OverlayWindowController already does. CleanupPane's WindowCloseObserver-based draft commit keeps working either way.

#### Overlay panel + SwiftUI hierarchy destroyed on hide and rebuilt on every dictation start
`OpenWhisp/Views/OverlayView.swift:84` — low/perf, fix risk moderate

hide()'s fade-out completion fully tears the overlay down (orderOut, detach the NSHostingController, nil the panel), so every dictation start pays for a brand-new NSPanel, NSHostingController, NSVisualEffectView-backed SwiftUI tree, and two 60fps TimelineView/Canvas views — constructed and first-laid-out on the main thread inside AppState.beginSession (AppState.swift:3941-3944 calls overlayController?.show() the instant the hotkey lands, while the same thread is also spinning up audio capture). show() only reuses the panel if the next dictation starts within the 0.14s fade window (the generation logic exists solely to make that race safe); every normal dictation takes the `panel == nil` branch and rebuilds. This adds main-thread work at the exact latency-critical hotkey-press moment (window-server surface creation for the borderless panel + vibrancy view + SwiftUI first render), …

*Suggested fix:* Keep the NSPanel and hosting controller alive across sessions: on hide, just orderOut (the OverlayView's TimelineViews stop ticking while the window is offscreen, and AppState already zeroes audioLevel on session end). If memory is the concern, defer the full teardown to a delayed task (e.g. 30s idle) instead of running it on every dictation boundary; the existing generation counter already fences that.

### Bridge / MCP / CLI

#### UNIX bridge server: unbounded thread-per-connection with no read/write timeouts, and stop() never severs accepted connections
`OpenWhisp/Services/AgentBridgeServer.swift:186` — medium/leak, fix risk moderate

`acceptLoop` spawns a dedicated Thread per accepted connection with no cap (the LAN twin caps at 8), the connection loop's `read(fd,...)` has no SO_RCVTIMEO/idle timeout, and `writeJSON`'s blocking `write` loop has no SO_SNDTIMEO. A client that connects and then hangs (an MCP host stopped in a debugger, a wedged agent harness holding the socket open) pins a full OS thread + fd indefinitely; N such connections pin N threads with no bound. `stop()` closes only `listenFD` — accepted connections aren't tracked or closed — so a connection thread parked in `read()` survives the user disabling the bridge in Settings (the `while isRunning` check is only re-evaluated after the blocking read returns). Bounded by the same-user + code-signature gate (any same-user binary once 'Allow unsigned clients' is on), so this is robustness rather than remote attack surface, but it is exactly the …

*Suggested fix:* Set SO_RCVTIMEO/SO_SNDTIMEO on accepted fds (e.g. a few minutes idle, a few seconds write) and re-check `isRunning` on EAGAIN; track accepted fds under stateLock so stop() can close them; optionally cap concurrent connections like the LAN server does.

#### One LAN connection's consent prompt (or any main-thread hop) blocks the single transport queue — listener, all other connections, handshake timeouts, and stop() teardown stall for up to 60s
`OpenWhisp/Services/LANBridgeServer.swift:531` — medium/perf, fix risk moderate

Every Network.framework callback — the listener's newConnectionHandler AND every LANConnection's receive/state handlers — runs on the one serial `queue`. `LANConnection.execute` processes intents inline on that queue and blocks it with `sem.wait()` in `blockOnHost`/`onMain` until the main thread answers. `consentGranted` for the `sync` scope can present the consent window, which waits for the user up to its 60s timeout (AgentConsentWindow.swift L108-109). Two execution contexts: connection A's frame handler parked in `sem.wait()` on the transport queue vs. the main thread waiting on the human. While parked: no new connections are accepted (phone retries stall in the TCP backlog or get no answer), other connections' frames aren't read, the 15s handshake timeouts can't fire (they're `queue.asyncAfter` blocks), and `stop()`'s teardown (`queue.async` in L207) is queued behind it — so …

*Suggested fix:* Give each LANConnection its own serial queue (listener on its own), so one connection's blocking hop can't stall accepts, other peers, or teardown. Alternatively make execute async (dispatch the host call and write the response from its completion) instead of semaphore-parking the shared queue.

#### BridgeClient has no read/connect timeout — 'openwhisp status' liveness probe and MCP tool calls hang forever on a wedged app
`Sources/OpenWhispBridgeKit/BridgeClient.swift:137` — medium/bug, fix risk moderate

BridgeClient sets F_SETNOSIGPIPE but never SO_RCVTIMEO/SO_SNDTIMEO, and readResponseLine loops on a fully blocking read(2) with no deadline. On the app side, EVERY verb — including `status` — synchronously hops to the main thread before answering (AgentBridgeServer.onMain / blockOnHost use DispatchQueue.main.async + semaphore, lines 377-391 and 487-496). If the app's main thread is busy (model load, modal dialog, beachball) the response never comes and the client blocks in read() indefinitely. Two execution contexts: the CLI/adapter thread parked in read(fd,...) forever, and the app's connection thread parked in sem.wait() for a main thread that never services the async block. Consequences: (1) `openwhisp status`, documented in usage as the liveness probe (main.swift:527), hangs precisely when the app is wedged — the one case a liveness probe must detect — breaking scripted probes like …

*Suggested fix:* Set SO_RCVTIMEO on the socket per call: a short deadline (a few seconds) for status/hello/history, and for blocking verbs (dictate/refine/transcribe.file) a deadline derived from the request's own timeout plus slack (e.g. resolvedTimeoutSeconds + 30s). Map the timeout to ClientError.unreachable (or a dedicated .timedOut) so the CLI exits with code 2/6 instead of hanging. Optionally stop the ProgressEmitter once elapsed exceeds total + slack.

#### MCP server is single-threaded: notifications/cancelled is never handled and cannot even be read during a blocking dictate — mic stays open up to 300s after the agent cancels
`Sources/OpenWhispBridgeKit/MCPServer.swift:57` — medium/bug, fix risk moderate

run() reads one stdin line at a time and handle()/dispatch()/callTool() execute synchronously on that same thread, so while a `tools/call` for openwhisp_dictate blocks in bridge.call (up to BridgeWire.DictateParams.maxTimeoutSeconds = 300s, BridgeWire.swift:562), no further stdin frame is read. MCP clients cancel an in-flight tool call by sending `notifications/cancelled`; this server (a) cannot read it while blocked, and (b) has no handler for it anyway — it falls through controlResponse's `default:` and, being a notification (id == nil), is silently dropped (MCPServer.swift:137). Concrete failure: the user presses Esc in Claude Code while the OpenWhisp voice overlay is up → the client sends notifications/cancelled and abandons the request → the overlay keeps listening with the mic open until the dictate timeout (up to 5 minutes), and the eventual transcript is written against a …

*Suggested fix:* Read stdin on a dedicated thread and dispatch tools/call handling off it (responses are already serialized by writeLock), or minimally: while a dictate is in flight, keep draining stdin and on `notifications/cancelled` for the in-flight request id open a second short-lived BridgeClient and issue `dictate.cancel`, then suppress the response frame for the cancelled id per the MCP cancellation contract.

#### openwhisp_refine has no keep-alive progress emitter — first-call consent prompt (up to 60s) or a slow local-LLM refine trips the client's ~60s tool timeout
`Sources/OpenWhispBridgeKit/MCPServer.swift:200` — medium/bug, fix risk safe

The dictate and transcribe_file branches both spin up a ProgressEmitter specifically because 'long answers don't trip an agent's tool-call timeout (Cursor ~60s)' (MCPServer.swift:174-176, 209-213). The refine branch does not, yet it blocks on the same bridge with two long-latency components: (1) the per-call consent resolution on the app side can include the user interacting with the consent window 'up to its 60s timeout' (AgentBridgeServer.swift:468-471) — so the FIRST refine from a new agent can sit 60s with zero frames on stdout; (2) the refine itself is a local-LLM generation whose latency on long text with a small on-device model can exceed 60s. Result: the client kills the tool call, the agent sees a timeout/failure, while the app still completes the refine and records bridgeDidCall — wasted generation and a confusing failure for exactly the tool whose error path was carefully …

*Suggested fix:* Extract the token-gated ProgressEmitter setup used by dictate/transcribe_file into a small helper and apply it to the refine branch too (indeterminate total, message e.g. "refining…").

#### BridgeRouter silently substitutes empty defaults when an optional-params method has a mistyped params object — a dictate's prompt/timeout are dropped without any error
`OpenWhisp/Services/BridgeRouter.swift:90` — low/bug, fix risk moderate

For methods whose params are all-optional (`dictate`, `history.list`, `sync.pull`), a params object that fails typed decode (one mistyped field, e.g. `"timeoutSeconds": "60"` as a string, or a numeric `prompt`) makes `decodeParams` return nil, and the router falls back to a fresh default struct instead of returning invalidParams. Failure scenario: a third-party client (explicitly supported via the unsigned-clients toggle) sends `dictate` with one wrong-typed field → the agent's prompt, timeout, language, context, and autoSubmit are ALL silently discarded; the user gets a promptless overlay and the default 60s timeout, and the agent gets a success response with no hint its parameters were ignored. Same shape for `sync.pull` (a mistyped cursor silently becomes a full first-page pull). This contradicts the required-params methods (`refine`, `sync.push`), which correctly error.

*Suggested fix:* Distinguish 'params key absent' (→ defaults, fine) from 'params present but undecodable' (→ invalidParams error), e.g. decode the envelope with a `params: JSONValue?` presence probe or attempt `ParamsEnvelope<P>` and, on throw with a present params key, return `invalidParams`.

#### MCP adapter never consults the bridge's advertised capabilities; BridgeClient.capabilities is dead state
`Sources/OpenWhispBridgeKit/BridgeClient.swift:34` — low/debt, fix risk moderate

BridgeWire.Capability documents the contract: 'Adapters use these to hide tools the running app doesn't offer (e.g. transcribeFile before v1.1)' (BridgeWire.swift:134-136). But MCPServer.toolDefinitions is a static constant always advertising all four tools, tools/list is answered without ever connecting to the bridge (the bridge is built lazily on first tools/call, MCPServer.swift:146-151), and PersistentBridge exposes no way to read capabilities. BridgeClient stores them (`private(set) var capabilities` — internal, not public) and nothing in the package or CLI reads the property after the handshake assigns it. Against an older app that lacks `transcribe.file`, the adapter advertises openwhisp_transcribe_file and the call fails at runtime with an unknown-method domain error instead of the tool being hidden. Bounded (clear error text reaches the agent) but it is a documented …

*Suggested fix:* Expose the handshake capabilities through PersistentBridge (e.g. connect eagerly on `initialize` or cache HelloResult), filter toolDefinitions by them in the tools/list reply, and emit `notifications/tools/list_changed` if the set changes after a reconnect — or delete the dead `capabilities` property if filtering is explicitly not wanted.

#### PersistentBridge retry re-sends non-idempotent dictate after it may have already executed
`Sources/OpenWhispBridgeKit/PersistentBridge.swift:66` — low/bug, fix risk moderate

PersistentBridge.call treats `.protocolError` as a transport failure and silently re-sends the SAME request on a fresh connection. `.protocolError` is thrown by BridgeClient.call not only for a dead socket but for any response that arrives but cannot be decoded (BridgeClient.swift:101-103 'undecodable response'), a response with neither result nor error (line 109), or a response exceeding the client-side 1 MiB cap (BridgeClient.swift:140-142 'response exceeded frame cap'). In all of those cases the app HAS already executed the request — for `dictate` the user already spoke and the mic session completed (AgentBridgeServer.execute runs blockingDictate, then send). The retry then re-opens a SECOND mic session with the same prompt: the user's first spoken answer is discarded and OpenWhisp starts listening again unprompted. For `openwhisp_transcribe_file`, a transcript larger than 1 MiB …

*Suggested fix:* Restrict the automatic retry to methods that are idempotent (status, history.list, dictate.stop, dictate.cancel) or to failures that provably happened before the request was delivered (e.g. connect/handshake/write failures — the initial `session()` connect and `writeAll` — never a failure raised while reading the response). For dictate/refine/transcribe.file, surface the protocol error to the agent instead of re-executing; the tool-result error text already tells the agent what happened.

#### git rev-parse subprocess runs per dictate call with no timeout, before the keep-alive emitter starts
`Sources/OpenWhispBridgeKit/WorkspaceContext.swift:94` — low/perf, fix risk safe

Every openwhisp_dictate tools/call (and every CLI `openwhisp dictate`) calls WorkspaceContext.resolved, which spawns `/usr/bin/env git -C <cwd> rev-parse --abbrev-ref HEAD` and blocks on readDataToEndOfFile() + waitUntilExit() with no deadline. In MCPServer.callTool the context is resolved at line 165, BEFORE the ProgressEmitter is created/started at lines 178-186 — so if git stalls (cwd on a hung network/FUSE mount, or a repo with a slow alias/wrapper resolution), the tool call blocks with zero frames on stdout and the client's ~60s timeout fires without ever reaching the bridge. In the normal case this is one fork/exec of git per dictation — small but repeated cost in the dictation hot path that could be cached per (cwd, HEAD-mtime) for the lifetime of the adapter process.

*Suggested fix:* Start the ProgressEmitter before resolving workspace context, and/or run the git probe with a short deadline (e.g. terminate the Process after ~1-2s and return nil) and cache the branch per cwd for the adapter's lifetime.

### Meetings & capture

#### MeetingSessionStore.upsert re-loads, re-decodes and re-encodes the entire unbounded meetings.json (full transcripts included) on the main actor for every status transition
`OpenWhisp/Services/MeetingSessionStore.swift:77` — medium/perf, fix risk moderate

`upsert(_:)` and `delete(id:)` are load-modify-save over the whole file: each call decodes ALL meetings from disk, mutates one, and re-encodes ALL of them — even though the caller (MeetingPipelineCoordinator, declared `@MainActor`, MeetingPipelineCoordinator.swift:28) already holds the full list in its `@Published meetings` and mirrors the result back (`private func persist(_ meeting: Meeting) { meetings = store.upsert(meeting) }`, line 676-678). `persist` fires from ~10 sites per meeting lifecycle (lines 194, 208, 255, 260, 370, 466, 546, 601, 616, 629, 635 — begin, transcribing, transcribed, summarizing, done, failed...). Unlike history (hard cap 200), meetings.json has NO retention cap, and each `Meeting` persists `transcript` (an hour-long meeting is ~50-100KB), `attributedTranscript` (the same text again as Me:/Them: lines) and `summary` (Meeting.swift:19-44). After months of …

*Suggested fix:* Have the coordinator pass its in-memory `meetings` as the source of truth: mutate the array it already holds and call `store.save(meetings)` once (no disk re-load), or give MeetingSessionStore an in-memory-cached save API. Longer term, split transcripts/summaries out of the index file (per-meeting sidecar files) so a status flip never re-encodes every transcript, and add a retention cap or size bound for meetings.json.

#### Quick stop-then-start deallocates the finalizing capture session — the stopped meeting's recording is dropped until next launch
`OpenWhisp/Services/MeetingCaptureSession.swift:234` — low/race, fix risk safe

stop() finalizes via `Task { [weak self] in await system?.stop(); self?.finalizeAndDeliver() }` — the session holds itself only through AppMain's single `meetingSession: Any?` strong reference. AppMain.stopMeeting() clears `meetingActive` synchronously (AppMain.swift line 465) without waiting for `.finished`, so startMeeting()'s `guard !meetingActive` passes immediately and line 415 `meetingSession = session` replaces the old session while its finalize Task is still awaiting SCK stop. With no other strong refs (onStateChanged/onFinished capture it weakly, the Task captures only `system` strongly), the old session deallocates and `self?.finalizeAndDeliver()` resolves to nil: the WAV header is never finalized and onFinished/ingest never fires. The just-stopped meeting vanishes from the pane; it is only salvaged by the orphan sweep at the NEXT app launch (AppMain line 80), so the user sees …

*Suggested fix:* Capture self strongly in stop()'s finalize Task (the session must outlive its own finalization), or keep `meetingActive`/`meetingInProgress` set until the `.finished`/`.failed` callback arrives.

#### MeetingCaptureSession.state written on the main thread, read on the session queue in legFailed — unsynchronized cross-thread access
`OpenWhisp/Services/MeetingCaptureSession.swift:284` — low/race, fix risk moderate

`state` is documented/handled as main-thread confined: every writer runs on main (`setState` at lines 414-417 is always called inside DispatchQueue.main.async, and `fail` at 409-412 runs on main in all call paths), and `start()`/`stop()` read it on main. But `legFailed` reads it on the private serial `queue`: line 282-284 `queue.async { guard let self, self.state == .recording, ... }`. That is an unsynchronized read of an enum with a String payload concurrently with main-thread writes — undefined behavior under the Swift memory model, and practically a stale-read window. Concrete scenario: a leg error fires in the window right after `setState(.recording)` is enqueued on main but before it executes (SCK/config-change errors can arrive immediately after startup) — the queue-side read sees the stale `.idle`/`.failed` value and the guard returns, so the leg failure is silently swallowed: …

*Suggested fix:* Keep a queue-confined capture flag (e.g. `isCapturing`, set true on `queue` when the writer opens and false in finalizeAndDeliver/legFailed) and guard legFailed on that plus `writer != nil` instead of reading main-confined `state` from the queue.

#### MeetingMicCapture.sampleQueue is dead code — conversion and onSamples actually run on the tap thread, contradicting the stated contract
`OpenWhisp/Services/MeetingMicCapture.swift:28` — low/debt, fix risk safe

The doc comment on `onSamples` (line 19-20) promises "Delivered on `sampleQueue`. Mono Float32 at 16 kHz", and a dedicated queue is declared (line 28), but the tap closure (lines 50-53) never dispatches to it: `convert(buffer)` (AVAudioConverter resample + output AVAudioPCMBuffer allocation + Array copy) and the `onSamples` callback run synchronously on the AVAudioEngine tap delivery thread. Today this is masked because the only consumer (MeetingCaptureSession.ingest) immediately hops to its own serial queue, so there is no data corruption — but the false contract is a trap for the next consumer (SystemAudioCapture's identically-documented onSamples IS delivered on its sampleQueue via addStreamOutput(sampleHandlerQueue:)), and the resample work sits on the tap delivery thread where sustained stalls can drop input buffers.

*Suggested fix:* Either dispatch the tap body onto sampleQueue (`sampleQueue.async { ... convert ... onSamples }`, retaining the buffer across the hop like AudioRecorder does), matching SystemAudioCapture's delivery contract — or delete the unused queue and correct the comment to say delivery happens on the tap thread.

#### MeetingMicCapture.sampleQueue is dead: onSamples is documented as delivered on it but actually fires on the AVAudioEngine tap thread
`OpenWhisp/Services/MeetingMicCapture.swift:52` — low/debt, fix risk safe

MeetingMicCapture declares `private let sampleQueue = DispatchQueue(label: "com.openwhisp.app.meeting.mic")` (line 28) and documents its callback contract as "Delivered on `sampleQueue`. Mono Float32 at 16 kHz." (line 19), but the tap closure invokes `self.onSamples?(samples)` directly on AVAudioEngine's internal tap-callback thread — sampleQueue is referenced nowhere else in the file. Its sibling SystemAudioCapture honors the same documented contract for real (SystemAudioCapture.swift:72 passes its queue as SCK's sampleHandlerQueue). Today this is latent because the only consumer, MeetingCaptureSession.ingest, immediately hops onto its own serial queue before touching the mixer/writer — but the false threading contract invites a future consumer (e.g. a live meeting-transcription tap, which MAK-52 makes plausible) to touch queue-confined state directly, believing it is on a known serial …

*Suggested fix:* Either make the contract true — wrap the delivery in `sampleQueue.async { self.onSamples?(samples) }` (also serializing convert()'s AVAudioConverter state, which is currently touched on the tap thread) — or delete the unused queue and correct the doc comment to say the callback fires on the tap thread and consumers must hop. The first option matches SystemAudioCapture and is the safer default.

### Audio & engines

#### WhisperKitStreamingEngine has no cancelLoading — rebuildFileEngine orphans an in-flight model download/load (dual-model residency)
`OpenWhisp/Services/WhisperKitStreamingEngine.swift:278` — medium/leak, fix risk safe

AppState.rebuildFileEngine explicitly cancels Parakeet's in-flight load before discarding that engine ('stop(cancel:) only tears down the mic/session, so switching variant mid-download would otherwise orphan a ~600 MB fetch') — but for the WhisperKit streaming engine it only calls `stop(cancel: true)` and replaces the instance. The engine's `inFlightLoad` Task (created in loadTaskOnMain) is unstructured and runs to completion regardless of the engine being deallocated: on the auto-download path that is up to 600s (WhisperKitBridge.downloadLoadTimeout) of network fetch plus the CoreML/GPU specialization, running concurrently with the NEW engine instance's own load. That parallel-CoreML-load pressure is the documented cause of the cold-start 'stuck' bug the file engine guards against (WhisperKitEngine.stopServer cancels inFlightLoad and bumps loadGeneration for exactly 'the dual-engine …

*Suggested fix:* Add `@MainActor func cancelLoading() { inFlightLoad?.cancel(); inFlightLoad = nil }` to WhisperKitStreamingEngine (mirroring ParakeetStreamingEngine) and call it in rebuildFileEngine before replacing the instance.

#### RMS computed twice per buffer with scalar per-sample loops; one copy runs on the tap callback thread (no vDSP)
`OpenWhisp/Services/AudioRecorder.swift:770` — low/perf, fix risk moderate

In the pause-based streaming path every tap buffer pays for the full-buffer RMS twice: the tap closure calls `publishLevel(from: buffer)` directly on the AVAudioEngine tap delivery thread (line 307), which runs the scalar `rmsLevel` loop over ALL channels x frames (lines 777-786), and then `handlePauseBasedBuffer` recomputes the identical `Self.rmsLevel(from: buffer)` on streamQueue (line 367). At 48 kHz / 2048-frame taps that is ~23 callbacks/s; on a multi-channel interface (e.g. an 8-ch aggregate device) the tap-thread loop does 8 x 2048 multiply-adds per callback, plus a closure allocation and DispatchQueue.main.async per buffer even when no VAD consumer needs the tap-side value. `applyAutoGain` (lines 678-680 peak scan, 720-723 gain+clamp) is likewise scalar per-sample on streamQueue. All of this is exactly the per-sample work vDSP does in one call (vDSP_rmsqv, vDSP_maxmgv, …

*Suggested fix:* Compute RMS once per buffer on streamQueue, reuse it for both VAD and the level callback (publish from there), and replace the scalar loops with vDSP_rmsqv / vDSP_maxmgv / vDSP_vsmul+vDSP_vclip. Skip the level pipeline entirely when onLevelChanged is nil.

#### WhisperEngine semaphore-bridged URLSession completions race their capture variables on timeout
`OpenWhisp/Services/WhisperEngine.swift:683` — low/race, fix risk safe

postInference captures `resultData/resultResponse/resultError` in a dataTask completion running on URLSession's delegate queue and reads them on the calling thread after `semaphore.wait(timeout: .now() + 130)`. When the wait times out but the completion has not yet run (a wedged whisper-server whose connection outlives the 120s request timeout by scheduling slop), the subsequent reads race the late writes — an unsynchronized cross-thread read/write on all three vars. The same pattern exists in healthCheck (`ok` written in the completion, read after a 1.2s wait vs the request's 1s timeout — an even tighter window that the 45s health-poll loop exercises every 0.25s during server warm-up). Practical impact is small (worst case a torn/blank read producing a spurious emptyResponse), but it is a genuine TSan-visible data race in a file whose header comments show TSan cleanliness was an …

*Suggested fix:* Protect the captured results with an NSLock plus a claimed flag (the TimeoutRace pattern already in AsyncTimeout.swift), so a timed-out waiter marks the exchange dead and the late completion discards its write instead of racing; or replace the semaphore bridge with a synchronous URLSession wrapper that owns the handoff.

### Text output & AX

#### Screen-context AX reads run synchronously on the main thread at dictation start with no messaging timeout
`OpenWhisp/Services/ScreenContextReader.swift:29` — medium/perf, fix risk moderate

readFocusedFieldText() issues up to four sequential synchronous AX IPC calls to the focused application (focused element, role, subrole, value) with no AXUIElementSetMessagingTimeout, and it is called from AppState.captureScreenContext (AppState.swift:4917) on the main actor inside startDictation — between the hotkey press and capture spin-up. Each AXUIElementCopyAttributeValue blocks until the TARGET app services the request; against a beachballing/paused frontmost app (the exact app the user is trying to dictate into) each call can hang for the system default AX timeout (~6s), freezing OpenWhisp's UI, overlay, and the main run loop that hosts the CGEventTap source (long enough stalls trip tapDisabledByTimeout, and the re-enable code at HotkeyMonitor.swift:331-335 itself runs on the blocked loop). Reading the value attribute of a huge document field also transfers the ENTIRE field text …

*Suggested fix:* Set a short messaging timeout on the elements used (AXUIElementSetMessagingTimeout, e.g. 0.25s) so a hung target degrades to "no context" instead of a multi-second UI stall — the feature is already fail-closed on nil. Reorder ScreenContextGate.decide so the cheap settings/allowlist check short-circuits before the secure-field AX probe is evaluated (or pass a closure), eliminating the redundant per-dictation AX call when the feature is off.

#### Synchronous AX IPC on the main actor in the per-chunk hot path (secure-field check per inserted chunk, correction watcher reads full field value), no AX messaging timeout set
`OpenWhisp/Services/SecureFieldDetector.swift:21` — medium/perf, fix risk moderate

SecureFieldDetector.focusedFieldIsSecure() performs three synchronous AXUIElementCopyAttributeValue calls (focused element, role, subrole), each a blocking XPC round-trip into the focused app. It is called on the @MainActor for EVERY inserted live delta: handleAppleSpeechPartial (AppState.swift:3573) runs it on each partial that produced a non-empty delta (roughly per spoken word, several times/second) and insertLiveChunk (AppState.swift:4184) runs it per WhisperKit chunk. AXCorrectionWatcher additionally documents "Call on the main queue" and both arm() and the +2.5 s fire() synchronously read the focused element AND its entire kAXValueAttribute value on the main queue after every final (AXCorrectionWatcher.swift:82-93, 104-134), plus a second secure-field check. The repo never calls AXUIElementSetMessagingTimeout, so every one of these calls can block up to the system default AX …

*Suggested fix:* Call AXUIElementSetMessagingTimeout(systemWide, ~0.2s) once for the elements used by these hot-path probes, and/or move the per-chunk secure-field probe off the main actor (e.g. cache the result per focus change via an NSWorkspace frontmost-app/focus observer instead of re-querying per delta); run AXCorrectionWatcher's snapshot/re-read on a utility queue and hop back to main only with the result.

#### SelectionReader clipboard fallback restores too early; a slow app's late Cmd+C permanently clobbers the user's clipboard
`OpenWhisp/Services/SelectionReader.swift:94` — medium/race, fix risk moderate

readViaClipboard() synthesizes Cmd+C, polls the pasteboard for at most 150 ms, then unconditionally restores the snapshotted clipboard. The two execution contexts are OpenWhisp's main thread (which does the clearContents + writeObjects restore at the deadline) and the target app's own process (which services the synthesized Cmd+C asynchronously, whenever its runloop gets to it). If the focused app takes longer than 150 ms to service the copy (busy Electron app, beachballing app), the sequence is: OpenWhisp restores the old clipboard -> the target app's late copy then writes the selection over it. Net result: the feature reports "no selection" (returns nil) AND the user's clipboard is silently replaced by the selected text with no restore ever happening — exactly the restored-too-early pasteboard clobber. Contrast: TextInserter's paste path guards its deferred restore with a changeCount …

*Suggested fix:* After the restore, either (a) schedule a delayed re-check (~1 s) that detects a post-restore pasteboard change whose content equals a late copy and re-restores via a changeCount-guarded write (mirroring TextInserter's deferred-restore pattern), or (b) lengthen the poll window and only restore once the changeCount is observed to change or a generous deadline passes, recording the post-restore changeCount so a late copy can be recognized and reverted.

#### AgentCLIRefiner blocks a Swift-concurrency cooperative thread for up to the 30s CLI timeout
`OpenWhisp/Models/AgentCLIRefiner.swift:31` — low/perf, fix risk safe

refine() wraps the fully blocking AgentCLIRunner.run in `Task.detached { … }`. Task.detached still runs on the shared cooperative thread pool (width ≈ CPU cores) — 'detached' only detaches from the actor, it does not provide a dedicated thread. AgentCLIRunner.run blocks that pool thread in `waitGroup.wait(timeout: deadline)` / group joins for up to config.timeout (default 30.0s, AgentCLIProvider.swift L46), e.g. a slow `claude -p` cold start. One stuck refine parks one of N cooperative threads for half a minute; a user retrying while the first hangs parks a second. On a low-core Mac this measurably starves other async work (streaming-session tasks, MainActor hops queued behind the pool) during the hot dictation path. Bounded — the pool survives and the timeout guarantees release — but it violates the forward-progress contract the rest of the codebase's async code relies on, and the …

*Suggested fix:* Bridge the blocking run through a continuation on a plain DispatchQueue (e.g. `withCheckedContinuation { cont in DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: AgentCLIRunner.run(text, config: config)) } }`), or give AgentCLIRunner a termination-handler-based async API so no thread waits.

#### NSEvent global+local monitors run permanently alongside a working CGEventTap, double-processing every input event
`OpenWhisp/Services/HotkeyMonitor.swift:113` — low/debt, fix risk moderate

start() installs the CGEventTap and then unconditionally calls startNSEventFallback(), so when the tap works (the normal case) every keyboard, flagsChanged, other-mouse, and — via the NSEvent mask — every scroll-wheel event system-wide is delivered to this app TWICE (tap + global monitor for other apps' events; tap + local monitor for own events) and run through handleEvent/handleNSEvent both times. Correctness survives because all trigger/refine paths are edge-debounced through HotkeyGesture.resolve against isPressed/isRefinePressed/isMousePressed, but two things slip through: handleEscape() has no debounce, so one Esc press dispatches TWO onCancel tasks to the main actor (HotkeyMonitor.swift:370-372 and 434-436 both fire; harmless only because AppState's cancel is idempotent), and the duplicated processing (plus high-rate scroll momentum events the tap doesn't even subscribe to) is …

*Suggested fix:* Only install the NSEvent monitors when the tap failed (`if port == nil { startNSEventFallback() }`), keeping the tapDisabledByTimeout re-enable as the tap's recovery path; or keep both but drop .scrollWheel from the NSEvent mask when the tap is live and add an edge guard to handleEscape.

#### AX insert verification copies the entire field value twice per live chunk and folds typography over the whole document per verification
`OpenWhisp/Services/TextInserter.swift:233` — low/perf, fix risk moderate

insertViaAccessibility reads kAXValueAttribute for the focused element twice per insert (before-snapshot at line 217 and read-back at line 233) — each a synchronous XPC copy of the element's ENTIRE value. Live-chunk sessions call insert per delta (per spoken word with Apple Speech), so dictating into a large document (long note, big text view whose AX value is the whole document) transfers the full document text twice per word. InsertVerifier.axInsertReflected then runs foldTypography over the full `current` value — 8 sequential replacingOccurrences passes, each allocating a full copy of the document string — plus a contains() scan (TextOutput.swift:80, 101-109). This runs on the background insert queue, so it does not block UI, but the serial queue means per-chunk latency grows with document size and insertion falls progressively behind speech in large documents.

*Suggested fix:* For verification, read a bounded tail of the value instead of the whole document where the element exposes kAXNumberOfCharacters + a ranged value read (AXUIElementCopyParameterizedAttributeValue with kAXStringForRangeParameterizedAttribute), and fold typography only over that tail + the needle; alternatively skip the before/after full-value verification when the value length exceeds a threshold and trust the AX status code (the existing nil/unverifiable path).

### Persistence & stores

#### Scratchpad persists the entire notes store with a synchronous atomic write on every keystroke
`OpenWhisp/Views/ScratchpadWindow.swift:319` — medium/perf, fix risk moderate

`textDidChange` runs on every keystroke in the scratchpad editor and calls `persist()`, which is `ScratchpadStore.save(notes)` — a full JSON encode of ALL notes (every note's complete body text) plus an atomic temp-write+rename, synchronously on the main thread (ScratchpadWindow.swift:230). `setText` also re-sorts the whole notes array per keystroke (Scratchpad.swift:126-133: `notes = ScratchpadNotes.ordered(notes)`), and `reloadList()` does a full `tableView?.reloadData()` per keystroke (line 325 -> 289). With a handful of large notes (the scratchpad is explicitly for dictating long text into), typing/dictation-append costs O(total scratchpad bytes) of JSON encoding + a disk write per character. The same codebase already identified this exact pattern as a problem for vocabulary and debounced it off the main actor (AppState.swift:5046-5063: "Rapid dictations ... collapse into one write …

*Suggested fix:* Debounce the save the way vocabulary does (coalescing timer + background serial queue snapshot write), flushing on window close/app terminate; keep `persist()` immediate only for structural ops (create/delete note).

### LLM / subprocess

#### Quit path deletes the PID file before child exit is confirmed, so a SIGTERM-slow llama-server orphans un-reapably
`OpenWhisp/Services/LlamaServerEngine.swift:388` — low/leak, fix risk moderate

On quit, AppMain.applicationWillTerminate → AppState.shutdown() (AppState.swift L2641-2651) → stopServer() → stopServerLocked(), which sends SIGTERM synchronously, schedules the SIGKILL escalation on a background queue with up to 2s of polling (ManagedServerProcess.terminateAsync, L207-221), and then immediately deletes the PID file. The app process exits right after applicationWillTerminate returns, so the escalation queue dies before it can ever SIGKILL. If the child does not exit promptly on SIGTERM — llama-server mid-model-load only checks its shutdown flag after the load completes (terminateAsync's own doc admits 'a busy server can take seconds to finish its graceful shutdown'), or a wedged Metal call hangs it — the server outlives the app holding ~0.7-1.5GB RAM and its port, and because the PID file was already removed, the next launch's reapStaleServer (whose stated purpose is …

*Suggested fix:* Only delete the PID file once the child's exit is confirmed (e.g. from terminateAsync's escalation block after isRunning goes false / after the SIGKILL), and leave it in place on the quit path so next-launch reapStaleServer can clean up a straggler. Optionally, in shutdown() do a short bounded synchronous wait (e.g. 200-500ms) for the child to exit before the app terminates.

### Build & packaging

#### build-dmg.sh word-splits its Swift source list (and the eval'd CC_ARGS word-split), silently diverging from build.sh's space-safe array — DMG builds break on any repo path containing a space
`build-dmg.sh:43` — low/debt, fix risk safe

build.sh was explicitly fixed to collect sources into a bash array 'so paths with spaces survive (no word-splitting)' (build.sh:29-33), but build-dmg.sh — which its comments claim is kept from drifting via shared helpers — still builds SWIFT_FILES as a single tr-joined string and expands it unquoted into swiftc. Its justification comment ('build paths have no spaces by construction') is false for the dominant variable in every path: PROJECT_DIR is wherever the user cloned the repo (e.g. '~/My Projects/openwhisp'). Failure scenario: a contributor whose checkout path contains a space finds ./build.sh works but ./build-dmg.sh fails with a wall of 'error: no such file or directory' for each path fragment — a confusing divergence between two scripts documented as never drifting. The same space-unsafety is re-introduced into build.sh itself via the intentionally word-split CC_ARGS ('-Xcc …

*Suggested fix:* Port build.sh's array-based source collection into build-dmg.sh (or extract the find-into-array into a shared sourced helper next to the link-args scripts so the glob and its exclusions live in one place), and have the dep scripts emit CC args as printf %q-quoted per-element arrays (or newline-separated values read into an array) instead of a single word-split string.

#### bundle-llama-runtime.sh transitive-dylib resolution silently gives up after 3 fixed passes with no completeness check
`scripts/bundle-llama-runtime.sh:106` — low/bug, fix risk safe

The script's own header and the direct-dependency guard (lines 80-93) exist to prevent 'silently dropping' a dylib and shipping a llama-server that dyld-fails on user machines. But the transitive resolution loop runs exactly 3 passes: pass N scans the dylibs currently in lib/ and copies anything missing, then the loop simply ends. Dylibs copied during pass 3 are never re-scanned, and there is no post-loop assertion that 'missing' ended up empty. Failure scenario: a llama.cpp bump splits ggml into a deeper dependency chain (4+ hops of @rpath deps, e.g. libggml-metal → libggml-base → libggml-cpu → new lib), package.sh/build-dmg.sh complete successfully, and the released app's built-in LLM fails at runtime with a dyld 'Library not loaded' error on user machines — exactly the silent partial-bundle failure mode the surrounding guards were written to prevent. Bounded today because current …

*Suggested fix:* Replace the fixed 3-pass loop with a loop that runs until a scan finds nothing missing, or keep the pass cap but add a final verification scan after the loop that exits 1 if any @rpath dep of any bundled dylib is still absent from lib/.
